//
// UtteranceTranscriber.swift
//
// Turns bursts of microphone audio into text, and owns the only speech-recognition
// task in the app.
//
// One task, not two, is the important decision here. The obvious design gives wake
// spotting its own lightweight recogniser and starts a second one for the question —
// and then "Hey Luna what does precision mean", said in a single breath, loses its
// question in the handover. Instead the recogniser opens when speech starts and stays
// open for the whole burst; the wake spotter and the session both read the same
// growing transcript. Waking up costs nothing because nothing is restarted.
//
// The recogniser is opened per burst rather than left running, because it is the
// expensive part. Between bursts there is no task at all: the pipeline's energy
// detector is the only thing awake.
//
// Apple caps a recognition task at roughly a minute. Questions are seconds long, so
// this only matters in a noisy room where the detector never settles — handled by
// rotating onto a fresh task and carrying the text across so the transcript reads as
// one continuous burst.
//

import AVFoundation
import os
import Foundation
import Speech

@MainActor
final class UtteranceTranscriber {

  enum Event: Sendable, Equatable {
    /// The running transcript of the burst in progress. Fires often.
    case partial(String)
    /// Speech stopped. Carries the last transcript seen for the burst, which is empty
    /// when the sound turned out not to be words.
    case burstEnded(String)
    /// On-device recognition is not usable — no model for the locale, or the
    /// recogniser reported itself unavailable.
    case unavailable(String)
  }

  let observers = ObserverRegistry<Event>()

  private(set) var isRunning = false
  private(set) var isPaused = false
  private(set) var currentTranscript = ""

  private let pipeline: VoiceAudioPipeline
  private let recognizer: SFSpeechRecognizer?

  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var sinkID: UUID?
  private var pipelineObserver: UUID?
  /// Identifies the current recognition task. Callbacks from a task that has already
  /// been replaced — by a rotation, or by the burst ending — arrive after the fact and
  /// would otherwise overwrite the transcript with stale text.
  private var activeGeneration: UUID?

  /// Text from earlier tasks in this same burst, carried across a rotation so the
  /// burst still reads as one utterance.
  private var carryOver = ""
  /// The raw text of the most recently emitted burst — what `retainLastBurst()`
  /// promotes into the next burst's seed.
  private var lastBurstText = ""
  /// Seed for the next burst. Set when the session judged the last burst to be
  /// half a sentence: a reader's mid-thought pause ends the burst (the energy
  /// detector can't know a hesitation from a full stop), and without this the
  /// next burst opens a fresh recogniser that has never heard the first half.
  /// "What does… [pause] …the table mean" must arrive as one question.
  private var pendingCarry = ""
  private var burstStartedAt = Date.distantPast

  /// Apple's ceiling is about 60s. Rotate before it so the cut is ours, not an error.
  private let rotateAfter: TimeInterval = 50

  init(pipeline: VoiceAudioPipeline, locale: Locale = Locale(identifier: "en-US")) {
    self.pipeline = pipeline
    self.recognizer = SFSpeechRecognizer(locale: locale)
  }

  // MARK: - Lifecycle

  func start() {
    guard !isRunning else { return }

    guard let recognizer, recognizer.isAvailable else {
      observers.send(.unavailable("Speech recognition isn't available right now."))
      return
    }
    guard recognizer.supportsOnDeviceRecognition else {
      // Falling back to the server would send every word a reader speaks to Apple,
      // which contradicts the promise the app makes. Better to say so.
      observers.send(.unavailable("On-device speech recognition isn't installed for English."))
      return
    }

    pipelineObserver = pipeline.observers.add { [weak self] event in
      self?.handlePipelineEvent(event)
    }
    isRunning = true

    // The pipeline may already be mid-burst when the session starts.
    if pipeline.isVoiceActive { beginBurst() }
  }

  func stop() {
    guard isRunning else { return }
    endBurst(emit: false)
    if let pipelineObserver { pipeline.observers.remove(pipelineObserver) }
    pipelineObserver = nil
    isRunning = false
    isPaused = false
    currentTranscript = ""
  }

  /// Stop consuming audio without tearing the session down.
  ///
  /// Used while Luna speaks. Her voice reaches the microphone through the speaker,
  /// and with no echo cancellation in v1 anything heard during playback is her, not
  /// the reader.
  func pause() {
    guard isRunning, !isPaused else { return }
    Log.stt.info("paused — microphone ignored until resume")
    isPaused = true
    endBurst(emit: false)
    pipeline.setDetectionEnabled(false)
  }

  func resume() {
    guard isRunning, isPaused else { return }
    Log.stt.info("resumed — listening again")
    isPaused = false
    currentTranscript = ""
    carryOver = ""
    clearRetainedBurst()
    pipeline.setDetectionEnabled(true)
  }

  /// Keep the last emitted burst and prepend it to the next one.
  ///
  /// Called by the session when a burst ended on half a thought — the hold is the
  /// session's decision (it knows what an answerable question looks like); making
  /// the text survive into the next burst is this class's.
  func retainLastBurst() {
    guard !lastBurstText.isEmpty else { return }
    Log.stt.info("retaining burst across pause: \"\(self.lastBurstText, privacy: .public)\"")
    pendingCarry = lastBurstText
  }

  /// Drop any held fragment — the question window expired without a continuation.
  func clearRetainedBurst() {
    pendingCarry = ""
    lastBurstText = ""
  }

  // MARK: - Pipeline events

  private func handlePipelineEvent(_ event: VoiceAudioPipeline.Event) {
    guard isRunning, !isPaused else { return }
    switch event {
    case .voiceBegan:
      beginBurst()
    case .voiceEnded:
      endBurst(emit: true)
    case .interrupted, .failed:
      endBurst(emit: false)
    case .interruptionEnded, .routeChanged:
      break
    }
  }

  // MARK: - Burst handling

  private func beginBurst() {
    guard task == nil else { return }
    Log.stt.info("burst began — opening recognition task")
    // A held fragment from the previous burst seeds this one, so a hesitation
    // splits the audio but never the sentence.
    carryOver = pendingCarry
    pendingCarry = ""
    currentTranscript = carryOver
    burstStartedAt = Date()
    openTask(replayingPreroll: true)
  }

  private func endBurst(emit: Bool) {
    guard task != nil || emit else { return }
    closeTask()

    // A burst that produced no recognition results still carries its seed: the
    // held fragment stands even when the new sound turned out not to be words.
    let text = (currentTranscript.isEmpty ? carryOver : currentTranscript)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    currentTranscript = ""
    carryOver = ""
    if emit {
      lastBurstText = text
      Log.stt.info("burst ended — final: \"\(text, privacy: .public)\"")
      observers.send(.burstEnded(text))
    } else {
      Log.stt.debug("burst closed without emitting")
    }
  }

  /// Opens a recognition task and points the microphone at it.
  ///
  /// `replayingPreroll` is what saves the first syllable: by the time energy
  /// detection is confident that speech started, a fraction of a second of audio has
  /// already gone by, and that fraction usually contains "Hey".
  private func openTask(replayingPreroll: Bool) {
    guard let recognizer else { return }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = true
    request.addsPunctuation = true
    // The vocabulary a reader asks about is, by definition, unusual. Nudging the
    // recogniser toward the wake phrase costs nothing and reduces missed wakes.
    request.contextualStrings = ["Hey Luna", "Luna"]
    self.request = request

    let generation = UUID()
    activeGeneration = generation

    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      Task { @MainActor in
        guard let self, self.activeGeneration == generation else { return }
        if let result {
          self.handleTranscript(result.bestTranscription.formattedString)
        }
        if error != nil {
          // Errors here are routine — a task ending after `endAudio` reports one. The
          // burst has already been emitted by then, so there is nothing to recover.
          self.closeTaskIfCurrent(generation)
        }
      }
    }

    if replayingPreroll {
      // One atomic attach: preroll, the audio that arrived while this very call was
      // being scheduled, and the live stream — in order, with nothing dropped at the
      // seams. Split into replay-then-attach, the gap between the two calls loses
      // the reader's first words.
      sinkID = pipeline.attachSinkReplayingBuffered { [weak request] buffer in
        request?.append(buffer)
      }
    } else {
      sinkID = pipeline.addSink { [weak request] buffer in
        request?.append(buffer)
      }
    }
  }

  private func closeTask() {
    activeGeneration = nil
    if let sinkID { pipeline.removeSink(sinkID) }
    sinkID = nil
    request?.endAudio()
    request = nil
    task?.cancel()
    task = nil
  }

  private func closeTaskIfCurrent(_ generation: UUID) {
    guard activeGeneration == generation else { return }
    closeTask()
  }

  private func handleTranscript(_ text: String) {
    let combined = carryOver.isEmpty ? text : "\(carryOver) \(text)"
    guard combined != currentTranscript else { return }
    currentTranscript = combined
    observers.send(.partial(combined))

    if Date().timeIntervalSince(burstStartedAt) >= rotateAfter {
      rotate()
    }
  }

  /// Swap onto a fresh recognition task mid-burst, keeping the text so far.
  ///
  /// Only reachable when someone talks for the better part of a minute without the
  /// energy detector ever settling — a café, usually, not a reader.
  private func rotate() {
    Log.stt.info("rotating recognition task at \(Int(Date().timeIntervalSince(self.burstStartedAt)), privacy: .public)s — carrying \(self.currentTranscript.count, privacy: .public) chars")
    carryOver = currentTranscript
    closeTask()
    burstStartedAt = Date()
    openTask(replayingPreroll: true)
  }
}
