//
// AVSpeechTTSEngine.swift
//
// The interim voice: Apple's built-in synthesiser.
//
// It is queue-shaped rather than call-and-wait, which is the whole point — clauses are
// handed over as the model produces them, so speech starts while generation is still
// running. AVSpeechSynthesizer queues utterances natively, so "enqueue" maps directly
// onto it and no buffering of our own is needed.
//
// This engine is deliberately temporary. It will make the app sound like every other
// utility on the phone, and the voice is supposed to be a reason to use Luna rather
// than something to tolerate — Kokoro replaces it in a later milestone. Everything
// above this file talks to `TTSEngine`, so that swap touches one line.
//
// Note: this type does NOT configure AVAudioSession. The voice session owns the audio
// session for the whole of its lifetime and must not have it reconfigured underneath;
// callers outside a session (the debug harness) activate playback themselves.
//

import AVFoundation
import Foundation

@MainActor
final class AVSpeechTTSEngine: NSObject, TTSEngine {

  private let synthesizer = AVSpeechSynthesizer()

  /// Utterances handed to the synthesiser that haven't finished or been cancelled.
  private var outstanding = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  /// Slightly under the default. Learners are parsing an unfamiliar word, and the
  /// default rate reads as brisk when the content is new.
  var rate: Float = 0.48
  var voiceIdentifier: String?

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  // MARK: - TTSEngine

  var isSpeaking: Bool {
    synthesizer.isSpeaking || outstanding > 0
  }

  func enqueue(_ clause: String) {
    let text = clause.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    outstanding += 1
    synthesizer.speak(makeUtterance(text, rate: rate))
  }

  func finishSpeaking() async {
    guard isSpeaking else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
    outstanding = 0
    releaseWaiters()
  }

  func speakWordSlowly(_ word: String) async {
    let text = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    // Once deliberately, then once at conversational speed — the pattern a person
    // uses when teaching someone to say a word.
    outstanding += 2
    synthesizer.speak(makeUtterance(text, rate: rate * 0.7, postDelay: 0.35))
    synthesizer.speak(makeUtterance(text, rate: rate))
    await finishSpeaking()
  }

  // MARK: - Utterance construction

  private func makeUtterance(
    _ text: String, rate: Float, postDelay: TimeInterval = 0
  ) -> AVSpeechUtterance {
    let utterance = AVSpeechUtterance(string: text)
    utterance.rate = rate
    utterance.postUtteranceDelay = postDelay
    utterance.voice = resolvedVoice()
    return utterance
  }

  private func resolvedVoice() -> AVSpeechSynthesisVoice? {
    if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
      return voice
    }
    // Prefer an enhanced/premium en-US voice when the user has downloaded one; the
    // default compact voice is markedly worse.
    let enUS = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
    if let premium = enUS.first(where: { $0.quality == .premium })
      ?? enUS.first(where: { $0.quality == .enhanced }) {
      return premium
    }
    return AVSpeechSynthesisVoice(language: "en-US")
  }

  private func releaseWaiters() {
    let pending = waiters
    waiters.removeAll()
    for continuation in pending { continuation.resume() }
  }

  fileprivate func utteranceFinished() {
    outstanding = max(0, outstanding - 1)
    if outstanding == 0 && !synthesizer.isSpeaking {
      releaseWaiters()
    }
  }
}

// MARK: - AVSpeechSynthesizerDelegate

extension AVSpeechTTSEngine: AVSpeechSynthesizerDelegate {

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in self.utteranceFinished() }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in self.utteranceFinished() }
  }
}
