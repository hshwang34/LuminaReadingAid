//
// KokoroTTSEngine.swift
//
// Luna's real voice: Kokoro-82M, on-device, via Core ML.
//
// AVSpeechSynthesizer made the app sound like every other utility on the phone;
// this is the milestone where the voice becomes a reason to use Luna. The engine
// still keeps an AVSpeech fallback inside it, and the handover is per-clause: until
// the Kokoro model is downloaded and warm, clauses route to the system voice, so a
// session started ten seconds after install speaks immediately and simply sounds
// better a minute later.
//
// Two hard-won constraints shape the implementation:
//
//  - Compute units are pinned to CPU + Neural Engine, never `.all`. `.all` includes
//    the GPU, and iOS refuses GPU work from a backgrounded app — the same
//    restriction that forced llama.cpp onto the CPU would silently kill synthesis
//    the moment the phone locks. The ANE has no such restriction.
//
//  - Synthesis is blocking and belongs to a background actor. A clause takes tens
//    of milliseconds of real compute; the main actor hears about it only when the
//    samples are ready to schedule.
//

import AVFoundation
import Foundation
import KokoroTTS
import os

@MainActor
final class KokoroTTSEngine: TTSEngine {

  // MARK: - State

  /// The system voice, used verbatim for every clause until Kokoro is warm.
  private let fallback = AVSpeechTTSEngine()
  private let synthesizer = KokoroSynthesizer()

  private(set) var isKokoroReady = false
  private var isPreparing = false

  private var playback: PlaybackNode?
  /// Clauses accepted but not yet fully played. Same identity-based accounting the
  /// AVSpeech engine settled on — a counter plus a stale callback is how a session
  /// dies quietly.
  private var pendingClauses = 0
  private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []
  private let waitCeiling: TimeInterval = 30

  /// Serialises synthesis order without blocking enqueue.
  private var workQueue: [(text: String, speed: Float)] = []
  private var isWorking = false
  private var generation = 0

  // MARK: - Preparation

  /// Download (first run, handled by the package) and warm the model.
  /// Safe to call repeatedly; the session fires this at start and forgets it.
  func prepare() async {
    guard !isKokoroReady, !isPreparing else { return }
    isPreparing = true
    defer { isPreparing = false }

    do {
      try await synthesizer.prepare()
      isKokoroReady = true
      Log.tts.info("kokoro ready — clauses now use the neural voice")
    } catch {
      // Not an error state the reader should meet: the fallback voice keeps
      // working, and the next session tries again.
      Log.tts.error("kokoro unavailable, staying on system voice: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - TTSEngine

  var isSpeaking: Bool {
    pendingClauses > 0 || isWorking || !workQueue.isEmpty || fallback.isSpeaking
  }

  func enqueue(_ clause: String) {
    let text = clause.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    guard isKokoroReady else {
      Log.tts.info("clause → system voice (kokoro not warm): \"\(text, privacy: .public)\"")
      fallback.enqueue(text)
      return
    }
    Log.tts.info("clause queued for kokoro: \"\(text, privacy: .public)\"")
    workQueue.append((text, 1.0))
    drainQueue()
  }

  func finishSpeaking() async {
    await fallback.finishSpeaking()
    guard isSpeaking else { return }
    let id = UUID()
    await withCheckedContinuation { continuation in
      waiters.append((id, continuation))
      Task { [weak self, waitCeiling] in
        try? await Task.sleep(for: .seconds(waitCeiling))
        self?.forceRelease(stuckWaiter: id)
      }
    }
  }

  func stop() {
    generation += 1
    workQueue.removeAll()
    pendingClauses = 0
    playback?.stop()
    playback = nil
    fallback.stop()
    releaseWaiters()
  }

  func speakWordSlowly(_ word: String) async {
    let text = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    guard isKokoroReady else {
      await fallback.speakWordSlowly(text)
      return
    }
    // Deliberate, then conversational — the pattern a person teaching a word uses.
    workQueue.append((text, 0.7))
    workQueue.append((text, 1.0))
    drainQueue()
    await finishSpeaking()
  }

  // MARK: - Work loop

  private func drainQueue() {
    guard !isWorking, !workQueue.isEmpty else { return }
    isWorking = true
    let myGeneration = generation

    Task { [weak self] in
      guard let self else { return }
      while let job = nextJob(ifGeneration: myGeneration) {
        do {
          let synthStarted = Date()
          Log.tts.info("kokoro synthesis started: \"\(job.text, privacy: .public)\"")
          let samples = try await synthesizer.synthesize(text: job.text, speed: job.speed)
          guard myGeneration == generation else { break }
          Log.tts.info("kokoro synthesis done in \(Int(Date().timeIntervalSince(synthStarted) * 1000), privacy: .public) ms — \(samples.count, privacy: .public) samples → playback")
          try schedule(samples)
        } catch {
          Log.tts.error("kokoro clause failed, falling back: \(error.localizedDescription, privacy: .public)")
          guard myGeneration == generation else { break }
          fallback.enqueue(job.text)
        }
      }
      finishWork(ifGeneration: myGeneration)
    }
  }

  private func nextJob(ifGeneration g: Int) -> (text: String, speed: Float)? {
    guard g == generation, !workQueue.isEmpty else { return nil }
    return workQueue.removeFirst()
  }

  private func finishWork(ifGeneration g: Int) {
    isWorking = false
    guard g == generation else { return }
    if !workQueue.isEmpty { drainQueue() }
    settleIfIdle()
  }

  // MARK: - Playback

  private func schedule(_ samples: [Float]) throws {
    guard !samples.isEmpty else { return }
    let node = try existingOrNewPlayback()
    guard let buffer = node.makeBuffer(from: samples) else { return }

    if pendingClauses == 0 {
      Log.tts.info("playback started — audio at the speaker")
    }
    pendingClauses += 1
    let myGeneration = generation
    node.play(buffer) { [weak self] in
      Task { @MainActor in
        guard let self, myGeneration == self.generation else { return }
        self.pendingClauses = max(0, self.pendingClauses - 1)
        if self.pendingClauses == 0, self.workQueue.isEmpty, !self.isWorking {
          Log.tts.info("playback finished — kokoro idle")
        }
        self.settleIfIdle()
      }
    }
  }

  private func existingOrNewPlayback() throws -> PlaybackNode {
    if let playback { return playback }
    let node = try PlaybackNode(sampleRate: KokoroSynthesizer.outputSampleRate)
    playback = node
    return node
  }

  private func settleIfIdle() {
    guard !isSpeaking else { return }
    releaseWaiters()
  }

  private func forceRelease(stuckWaiter id: UUID) {
    guard waiters.contains(where: { $0.id == id }) else { return }
    Log.tts.fault("kokoro watchdog fired — releasing \(self.waiters.count, privacy: .public) waiter(s)")
    pendingClauses = 0
    workQueue.removeAll()
    releaseWaiters()
  }

  private func releaseWaiters() {
    let released = waiters
    waiters.removeAll()
    for waiter in released { waiter.continuation.resume() }
  }
}

// MARK: - Synthesis actor

/// Owns the Kokoro model and runs its blocking synthesis off the main actor.
/// The model never leaves this actor, which is what makes the arrangement safe
/// without auditing the package's Sendable story.
actor KokoroSynthesizer {

  static let outputSampleRate: Double = 24_000

  /// The voice the product ships with. Warm, clear, and the reason the milestone
  /// exists — chosen during model research, MOS 4.2.
  static let voice = "af_heart"

  private var model: KokoroTTSModel?

  func prepare() async throws {
    guard model == nil else { return }
    let loaded = try await KokoroTTSModel.fromPretrained(
      // `.all` would include the GPU, which iOS forbids from a backgrounded app.
      // CPU + ANE synthesises everywhere, including with the phone locked.
      computeUnits: .cpuAndNeuralEngine,
      progressHandler: { fraction, stage in
        Log.tts.info("kokoro download: \(Int(fraction * 100), privacy: .public)% — \(stage, privacy: .public)")
      }
    )
    try loaded.warmUp()
    model = loaded
  }

  func synthesize(text: String, speed: Float) throws -> [Float] {
    guard let model else { throw KokoroError.notReady }
    return try model.synthesize(
      text: text, voice: KokoroSynthesizer.voice, language: "en", speed: speed
    )
  }

  enum KokoroError: Error { case notReady }
}

// MARK: - Playback node

/// A tiny output stack: engine → player → mixer, at Kokoro's native 24 kHz mono.
/// Kept separate from the session's input engine — input and output lifecycles
/// must not be able to take each other down.
@MainActor
private final class PlaybackNode {

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let format: AVAudioFormat

  init(sampleRate: Double) throws {
    guard let format = AVAudioFormat(
      standardFormatWithSampleRate: sampleRate, channels: 1
    ) else { throw Failure.badFormat }
    self.format = format

    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    try engine.start()
    player.play()
  }

  func makeBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
    ) else { return nil }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
    }
    return buffer
  }

  func play(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) {
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
      completion()
    }
  }

  func stop() {
    player.stop()
    engine.stop()
  }

  enum Failure: Error { case badFormat }
}
