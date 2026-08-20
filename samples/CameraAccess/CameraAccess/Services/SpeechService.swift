//
// SpeechService.swift
//
// On-device speech-to-text (STT) and text-to-speech (TTS) service.
// Uses Apple Speech framework for STT and AVSpeechSynthesizer for TTS.
//

import AVFoundation
import Speech

@MainActor
@Observable
final class SpeechService: NSObject {

  enum State {
    case idle
    case listening
    case speaking
  }

  private(set) var state: State = .idle
  private(set) var currentTranscript: String = ""

  private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
  private let synthesizer = AVSpeechSynthesizer()
  private var audioEngine = AVAudioEngine()
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var speechContinuation: CheckedContinuation<Void, Never>?

  // VAD (voice-activity-detection) state used by listenUntilSilence.
  // These are only valid while the VAD listen call is in progress.
  private var vadLatestTranscript: String = ""
  private var vadHasAnySpeech: Bool = false
  private var vadLastUpdateTime: Date = Date()

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  // MARK: - Permissions

  func requestPermissions() async -> Bool {
    let speechAuthorized = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }

    let micAuthorized: Bool
    if #available(iOS 17.0, *) {
      micAuthorized = await AVAudioApplication.requestRecordPermission()
    } else {
      micAuthorized = await withCheckedContinuation { continuation in
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          continuation.resume(returning: granted)
        }
      }
    }

    return speechAuthorized && micAuthorized
  }

  // MARK: - STT

  func startListening() throws {
    guard state == .idle else { return }

    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    guard let recognitionRequest else { return }
    recognitionRequest.requiresOnDeviceRecognition = true
    recognitionRequest.shouldReportPartialResults = true

    currentTranscript = ""

    recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
      guard let self else { return }
      Task { @MainActor in
        if let result {
          self.currentTranscript = result.bestTranscription.formattedString
        }
        if error != nil || (result?.isFinal ?? false) {
          // Recognition ended
        }
      }
    }

    let inputNode = audioEngine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
      self?.recognitionRequest?.append(buffer)
    }

    audioEngine.prepare()
    try audioEngine.start()

    state = .listening
  }

  func stopListening() -> String {
    guard state == .listening else { return currentTranscript }

    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionRequest = nil
    recognitionTask = nil

    state = .idle

    return currentTranscript
  }

  /// Starts listening and automatically stops when either:
  ///   - `noSpeechTimeout` seconds have elapsed without any recognized speech, OR
  ///   - `silenceTimeout` seconds have elapsed since the last new partial result
  ///     after speech began.
  ///
  /// This is the async end-of-speech-detection entry point used by the word
  /// conversation coordinator. It returns the final transcript (empty if no
  /// speech was ever recognized). Supports Task cancellation.
  func listenUntilSilence(
    noSpeechTimeout: TimeInterval = 5.0,
    silenceTimeout: TimeInterval = 1.5
  ) async throws -> String {
    guard state == .idle else { return "" }

    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

    recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    guard let recognitionRequest else { return "" }
    recognitionRequest.requiresOnDeviceRecognition = true
    recognitionRequest.shouldReportPartialResults = true

    currentTranscript = ""
    vadLatestTranscript = ""
    vadHasAnySpeech = false
    vadLastUpdateTime = Date()

    recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, _ in
      guard let self else { return }
      Task { @MainActor in
        guard let result else { return }
        let text = result.bestTranscription.formattedString
        // Only bump the VAD timestamp when new content arrives — speech framework
        // fires partials frequently even without new words, which would otherwise
        // prevent silence detection from ever triggering.
        if !text.isEmpty && text != self.vadLatestTranscript {
          self.vadLatestTranscript = text
          self.currentTranscript = text
          self.vadHasAnySpeech = true
          self.vadLastUpdateTime = Date()
        }
      }
    }

    let inputNode = audioEngine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
      self?.recognitionRequest?.append(buffer)
    }

    audioEngine.prepare()
    try audioEngine.start()

    state = .listening
    let startTime = Date()

    // Poll for stopping conditions. 150 ms granularity is smooth enough for
    // 1.5 s silence detection without burning CPU.
    while state == .listening {
      do {
        try await Task.sleep(for: .milliseconds(150))
      } catch {
        // Task cancelled — stop and return whatever we have.
        _ = stopListening()
        throw CancellationError()
      }

      let now = Date()
      if !vadHasAnySpeech {
        if now.timeIntervalSince(startTime) >= noSpeechTimeout {
          break
        }
      } else {
        if now.timeIntervalSince(vadLastUpdateTime) >= silenceTimeout {
          break
        }
      }
    }

    return stopListening()
  }

  // MARK: - TTS

  func speak(text: String) async {
    guard !text.isEmpty else { return }

    state = .speaking

    let utterance = AVSpeechUtterance(string: text)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    utterance.pitchMultiplier = 1.0
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

    await withCheckedContinuation { continuation in
      self.speechContinuation = continuation
      self.synthesizer.speak(utterance)
    }

    // Short settle delay before returning — prevents an audible click/jitter
    // when the caller immediately reactivates the mic and switches the
    // AVAudioSession from playback back into record mode.
    try? await Task.sleep(for: .milliseconds(250))

    state = .idle
  }

  // MARK: - Cleanup

  func stopAll() {
    if state == .listening {
      _ = stopListening()
    }
    if state == .speaking {
      synthesizer.stopSpeaking(at: .immediate)
      if let continuation = speechContinuation {
        speechContinuation = nil
        continuation.resume()
      }
    }
    state = .idle
  }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechService: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in
      if let continuation = self.speechContinuation {
        self.speechContinuation = nil
        continuation.resume()
      }
    }
  }
}
