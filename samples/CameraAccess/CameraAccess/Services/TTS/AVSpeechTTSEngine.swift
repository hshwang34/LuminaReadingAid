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
import os
import Foundation

@MainActor
final class AVSpeechTTSEngine: NSObject, TTSEngine {

  private let synthesizer = AVSpeechSynthesizer()

  /// Utterances handed to the synthesiser that haven't finished or been cancelled,
  /// tracked by identity rather than by count.
  ///
  /// A bare counter has two failure modes that both end a voice session: a stale
  /// `didCancel` from a stopped utterance decrements on behalf of a newer one, and —
  /// the one that actually bit — release was gated on `synthesizer.isSpeaking`, which
  /// is often still true at the moment the final `didFinish` arrives, so the last
  /// callback declined to release and no further callback was ever coming. Anything
  /// awaiting `finishSpeaking()` then hangs forever; in a session that means the turn
  /// never completes, the transcriber stays paused, and every wake after the first
  /// answer lands on a microphone nobody is listening to.
  private var pending = Set<AVSpeechUtterance>()
  private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

  /// Upper bound on any single `finishSpeaking()` wait. Answers are at most a couple
  /// of sentences, so half a minute is generously past legitimate speech. This exists
  /// because the failure mode of a lost synthesiser callback is not a glitch but a
  /// dead session — the turn never completes and the microphone never resumes — and
  /// that must not be possible no matter what AVFoundation does.
  private let waitCeiling: TimeInterval = 30

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
    synthesizer.isSpeaking || !pending.isEmpty
  }

  func enqueue(_ clause: String) {
    let text = clause.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    Log.tts.info("system voice speaking: \"\(text, privacy: .public)\"")
    let utterance = makeUtterance(text, rate: rate)
    pending.insert(utterance)
    synthesizer.speak(utterance)
  }

  func finishSpeaking() async {
    // Wait only when a callback is still owed to us. `synthesizer.isSpeaking` is
    // deliberately not consulted: it can be true with `pending` empty (the tail of a
    // cancelled utterance), and waiting on it would be waiting for a callback that
    // has already happened.
    guard !pending.isEmpty else { return }
    let id = UUID()
    await withCheckedContinuation { continuation in
      waiters.append((id, continuation))
      Task { [weak self, waitCeiling] in
        try? await Task.sleep(for: .seconds(waitCeiling))
        self?.forceRelease(stuckWaiter: id)
      }
    }
  }

  /// Watchdog path: a waiter outlived the ceiling, so the callback accounting has
  /// failed in a way this type promised could not happen. Trust is gone — drop the
  /// tracking state entirely and let everyone waiting proceed.
  private func forceRelease(stuckWaiter id: UUID) {
    guard waiters.contains(where: { $0.id == id }) else { return }
    Log.tts.fault("watchdog fired — a synthesiser callback was lost; force-releasing \(self.waiters.count, privacy: .public) waiter(s)")
    pending.removeAll()
    releaseWaiters()
  }

  func stop() {
    // Forget ours before stopping: the didCancel callbacks that follow must find
    // nothing to account for, or they would decrement on behalf of whatever is
    // enqueued next.
    pending.removeAll()
    synthesizer.stopSpeaking(at: .immediate)
    releaseWaiters()
  }

  func speakWordSlowly(_ word: String) async {
    let text = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    // Once deliberately, then once at conversational speed — the pattern a person
    // uses when teaching someone to say a word.
    let slow = makeUtterance(text, rate: rate * 0.7, postDelay: 0.35)
    let natural = makeUtterance(text, rate: rate)
    pending.insert(slow)
    pending.insert(natural)
    synthesizer.speak(slow)
    synthesizer.speak(natural)
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
    let released = waiters
    waiters.removeAll()
    for waiter in released { waiter.continuation.resume() }
  }

  fileprivate func utteranceFinished(_ utterance: AVSpeechUtterance) {
    // Only account for utterances we are still tracking — a callback for one that
    // stop() already forgot belongs to a previous life of the queue.
    guard pending.remove(utterance) != nil else { return }
    if pending.isEmpty {
      Log.tts.info("queue drained")
      releaseWaiters()
    }
  }
}

// MARK: - AVSpeechSynthesizerDelegate

extension AVSpeechTTSEngine: AVSpeechSynthesizerDelegate {

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in self.utteranceFinished(utterance) }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in self.utteranceFinished(utterance) }
  }
}
