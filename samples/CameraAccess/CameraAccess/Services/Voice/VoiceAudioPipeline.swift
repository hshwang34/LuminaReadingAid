//
// VoiceAudioPipeline.swift
//
// The one place in the app that owns the microphone.
//
// Everything about this file follows from a single iOS rule: an app may keep
// recording after the screen locks, but only if the audio session was activated
// while unlocked and is never deactivated in the background. So the engine and its
// tap start once, at session start, and run continuously until the reader ends the
// session. Consumers attach and detach; the tap itself never stops. Stopping it —
// even briefly, even "just to save power" — would end the session's ability to hear
// the next question, and there is no way to restart it from the lock screen.
//
// The second constraint is battery. A speech recogniser running for an hour costs
// 8-15% of a charge, which is not something to spend on a reader who asks four
// questions in that hour. So the tap does energy detection itself — cheap arithmetic
// on buffers it already has — and only opens the recogniser during bursts of actual
// speech. In a quiet room the expensive layer is off almost all the time.
//
// A ring buffer covers the seam. Voice detection needs a couple of frames to be sure
// speech started, and by then the first syllable of "Hey Luna" has already gone past.
// Those frames are retained and replayed into the recogniser when it opens, so the
// wake phrase arrives whole.
//

import AVFoundation
import os
import Foundation
import Speech

@MainActor
final class VoiceAudioPipeline {

  // MARK: - Events

  enum Event: Sendable, Equatable {
    /// Energy crossed the speech threshold — a burst has begun.
    case voiceBegan
    /// Energy has been below threshold long enough to call the burst finished.
    case voiceEnded
    /// A phone call, Siri, or another app took the session.
    case interrupted
    /// The interruption ended. `shouldResume` is the system's hint; when the phone is
    /// locked we cannot act on it silently, which is what the notification is for.
    case interruptionEnded(shouldResume: Bool)
    /// Headphones in or out — the tap must be reinstalled at the new format.
    case routeChanged
    case failed(String)
  }

  // MARK: - Tuning

  struct Tuning: Sendable {
    /// Never treat anything quieter than this as speech, however quiet the room is.
    /// Without it, a silent room drives the adaptive floor so low that a page turn
    /// opens the recogniser.
    var absoluteThresholdDB: Float = -45
    /// How far above the measured room tone a sound must sit to count as speech.
    var speechMarginDB: Float = 8
    /// Consecutive loud frames before a burst is declared. Two frames is ~40ms —
    /// enough to reject a click, short enough that the ring buffer covers the rest.
    var attackFrames: Int = 2
    /// Quiet time before a burst is declared over.
    ///
    /// This is the pause a person is allowed mid-sentence. 0.7s proved too eager on
    /// device: "Can you… explain what divine means" was split at the hesitation, and
    /// half a thought was sent off to be answered. 1.2s survives a natural gather-
    /// your-words pause; the latency cost is real but is paid once, after the reader
    /// has finished talking.
    var releaseSeconds: TimeInterval = 1.2
    /// Audio retained ahead of a burst, replayed into the recogniser when it opens.
    var prerollSeconds: TimeInterval = 1.5
  }

  // MARK: - State

  private(set) var isRunning = false
  private(set) var isVoiceActive = false
  /// Most recent input level in dBFS. Drives the listening indicator's liveliness.
  private(set) var inputLevelDB: Float = -100

  var tuning = Tuning() {
    didSet { tap.updateTuning(tuning) }
  }

  let observers = ObserverRegistry<Event>()

  private let engine = AVAudioEngine()
  private let tap = TapProcessor()
  private var isSessionConfigured = false
  private var notificationObservers: [NSObjectProtocol] = []

  /// Format the tap is installed at. Consumers need it to build recognition requests.
  private(set) var format: AVAudioFormat?

  // MARK: - Lifecycle

  /// Requests permissions, configures the audio session, and starts the engine.
  ///
  /// Must be called while the app is in the foreground. There is no background path
  /// into this method by design — iOS will not grant the microphone to a locked
  /// device, and pretending otherwise only produces a session that silently hears
  /// nothing.
  func start() async throws {
    guard !isRunning else { return }

    guard await Self.requestPermissions() else {
      throw PipelineError.permissionDenied
    }

    try configureSessionOnce()

    let session = AVAudioSession.sharedInstance()
    let inputNode = engine.inputNode
    // Read the format only after the session is active — before that the hardware
    // format is unset and reports 0 Hz, which crashes installTap.
    let format = inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0 else { throw PipelineError.noInput }
    self.format = format

    tap.configure(
      tuning: tuning,
      sampleRate: format.sampleRate,
      format: format,
      onActivity: { [weak self] active, level in
        Task { @MainActor in self?.handleActivity(active, level: level) }
      }
    )

    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [tap] buffer, _ in
      tap.process(buffer)
    }

    engine.prepare()
    do {
      try engine.start()
    } catch {
      inputNode.removeTap(onBus: 0)
      throw error
    }

    registerNotifications(session: session)
    isRunning = true
    Log.audio.info("engine started — \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")
  }

  /// Full teardown, including deactivating the audio session.
  ///
  /// Only safe to call in the foreground. Deactivating while backgrounded is what
  /// permanently kills a locked session, so the controller ends sessions by stopping
  /// the engine and defers this until the app is frontmost again.
  func stop(deactivateSession: Bool = true) {
    guard isRunning else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    tap.reset()
    isRunning = false
    isVoiceActive = false

    for observer in notificationObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    notificationObservers.removeAll()

    if deactivateSession {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      isSessionConfigured = false
    }
    Log.audio.info("engine stopped (deactivated session: \(deactivateSession, privacy: .public))")
  }

  // MARK: - Consumers

  /// Attach a sink that receives microphone buffers *while a burst is in progress*.
  /// Sinks are called on the audio thread and must do essentially nothing —
  /// appending to a recognition request is exactly the right amount of work.
  @discardableResult
  func addSink(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> UUID {
    tap.addSink(sink)
  }

  func removeSink(_ id: UUID) {
    tap.removeSink(id)
  }

  /// Audio captured just before the current burst was declared, oldest first.
  /// Replayed into a recogniser that opens mid-burst so its first word is intact.
  func preroll() -> [AVAudioPCMBuffer] {
    tap.preroll()
  }

  /// Stop and start energy detection without touching the engine. Used while Luna is
  /// speaking: her own voice comes back through the microphone, and with no echo
  /// cancellation in v1 the only honest response is to stop listening until she
  /// finishes.
  func setDetectionEnabled(_ enabled: Bool) {
    tap.setDetectionEnabled(enabled)
    if !enabled, isVoiceActive {
      isVoiceActive = false
      observers.send(.voiceEnded)
    }
  }

  // MARK: - Session configuration

  private func configureSessionOnce() throws {
    guard !isSessionConfigured else { return }
    let session = AVAudioSession.sharedInstance()

    // `.allowBluetooth` is the option that routes the microphone to a headset. Newer
    // SDKs renamed it to `.allowBluetoothHFP`; the old spelling still compiles and
    // still works, and a deprecation warning is a smaller cost than an availability
    // fork over a single flag.
    try session.setCategory(
      .playAndRecord,
      mode: .spokenAudio,
      options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
    )
    // Deliberately without `.notifyOthersOnDeactivation` semantics in mind: this
    // session is activated once and left active for its whole life.
    try session.setActive(true)
    isSessionConfigured = true
  }

  private static func requestPermissions() async -> Bool {
    let microphone = await AVAudioApplication.requestRecordPermission()
    guard microphone else { return false }

    return await withCheckedContinuation { continuation in
      SFSpeechRecognizerAuthorizationHelper.request { continuation.resume(returning: $0) }
    }
  }

  // MARK: - Notifications

  private func registerNotifications(session: AVAudioSession) {
    let center = NotificationCenter.default

    notificationObservers.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: session, queue: .main
      ) { [weak self] note in
        MainActor.assumeIsolated { self?.handleInterruption(note) }
      }
    )

    notificationObservers.append(
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: session, queue: .main
      ) { [weak self] note in
        MainActor.assumeIsolated { self?.handleRouteChange(note) }
      }
    )

    notificationObservers.append(
      center.addObserver(
        forName: AVAudioSession.mediaServicesWereResetNotification,
        object: session, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          // Everything audio-related is invalid after a media services reset. There is
          // no in-place recovery; the session has to be rebuilt from the foreground.
          self?.observers.send(.failed("Audio services restarted."))
        }
      }
    )
  }

  private func handleInterruption(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

    switch type {
    case .began:
      Log.audio.warning("interruption began — engine paused")
      engine.pause()
      isVoiceActive = false
      observers.send(.interrupted)

    case .ended:
      let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
      Log.audio.info("interruption ended — shouldResume: \(shouldResume, privacy: .public)")
      observers.send(.interruptionEnded(shouldResume: shouldResume))

    @unknown default:
      break
    }
  }

  /// Reinstall the tap when the hardware format changes underneath it.
  private func handleRouteChange(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }

    switch reason {
    case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange:
      guard isRunning else { return }
      let inputNode = engine.inputNode
      let newFormat = inputNode.outputFormat(forBus: 0)
      guard newFormat.sampleRate > 0 else { return }
      if let format, format == newFormat { return }

      inputNode.removeTap(onBus: 0)
      engine.stop()
      self.format = newFormat
      tap.configure(
        tuning: tuning,
        sampleRate: newFormat.sampleRate,
        format: newFormat,
        onActivity: { [weak self] active, level in
          Task { @MainActor in self?.handleActivity(active, level: level) }
        }
      )
      inputNode.installTap(onBus: 0, bufferSize: 1024, format: newFormat) { [tap] buffer, _ in
        tap.process(buffer)
      }
      do {
        try engine.start()
        Log.audio.info("route changed — tap reinstalled at \(newFormat.sampleRate, privacy: .public) Hz")
        observers.send(.routeChanged)
      } catch {
        isRunning = false
        observers.send(.failed("Lost the microphone after an audio route change."))
      }

    default:
      break
    }
  }

  // MARK: - Activity

  private func handleActivity(_ active: Bool, level: Float) {
    inputLevelDB = level
    guard active != isVoiceActive else { return }
    isVoiceActive = active
    Log.audio.info("\(active ? "voice began" : "voice ended", privacy: .public) (\(Int(level), privacy: .public) dB)")
    observers.send(active ? .voiceBegan : .voiceEnded)
  }

  enum PipelineError: LocalizedError {
    case permissionDenied
    case noInput

    var errorDescription: String? {
      switch self {
      case .permissionDenied:
        "Luna needs microphone and speech recognition access to listen."
      case .noInput:
        "No microphone input is available right now."
      }
    }
  }
}

// MARK: - Tap processor

/// The part that runs on the audio thread.
///
/// Isolated from the actor world on purpose: a render callback cannot await, cannot
/// allocate freely, and must never block. It holds its own lock, does fixed-cost
/// arithmetic, and hands decisions across the boundary as plain values.
private final class TapProcessor: @unchecked Sendable {

  private let lock = NSLock()

  private var sinks: [UUID: @Sendable (AVAudioPCMBuffer) -> Void] = [:]
  private var ring: [AVAudioPCMBuffer] = []
  private var ringFrames: AVAudioFrameCount = 0
  private var maxRingFrames: AVAudioFrameCount = 0

  private var tuning = VoiceAudioPipeline.Tuning()
  private var sampleRate: Double = 48_000
  private var format: AVAudioFormat?
  private var onActivity: (@Sendable (Bool, Float) -> Void)?

  private var detectionEnabled = true
  private var isActive = false
  private var framesAboveThreshold = 0
  private var lastAboveThreshold = Date.distantPast
  /// Adaptive estimate of room tone. Falls quickly so a move to a quiet room is
  /// noticed at once, rises slowly so a single sentence never becomes the floor.
  private var noiseFloorDB: Float = -60

  func configure(
    tuning: VoiceAudioPipeline.Tuning,
    sampleRate: Double,
    format: AVAudioFormat,
    onActivity: @escaping @Sendable (Bool, Float) -> Void
  ) {
    lock.lock()
    defer { lock.unlock() }
    self.tuning = tuning
    self.sampleRate = sampleRate
    self.format = format
    self.onActivity = onActivity
    self.maxRingFrames = AVAudioFrameCount(sampleRate * tuning.prerollSeconds)
    ring.removeAll()
    ringFrames = 0
    isActive = false
    framesAboveThreshold = 0
    noiseFloorDB = -60
  }

  func updateTuning(_ tuning: VoiceAudioPipeline.Tuning) {
    lock.lock()
    defer { lock.unlock() }
    self.tuning = tuning
    self.maxRingFrames = AVAudioFrameCount(sampleRate * tuning.prerollSeconds)
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    ring.removeAll()
    ringFrames = 0
    sinks.removeAll()
    isActive = false
    onActivity = nil
  }

  func setDetectionEnabled(_ enabled: Bool) {
    lock.lock()
    defer { lock.unlock() }
    detectionEnabled = enabled
    if !enabled {
      isActive = false
      framesAboveThreshold = 0
      ring.removeAll()
      ringFrames = 0
    }
  }

  @discardableResult
  func addSink(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> UUID {
    let id = UUID()
    lock.lock()
    sinks[id] = sink
    lock.unlock()
    return id
  }

  func removeSink(_ id: UUID) {
    lock.lock()
    sinks.removeValue(forKey: id)
    lock.unlock()
  }

  func preroll() -> [AVAudioPCMBuffer] {
    lock.lock()
    defer { lock.unlock() }
    return ring
  }

  // MARK: Audio thread

  func process(_ buffer: AVAudioPCMBuffer) {
    let level = Self.levelDB(of: buffer)

    lock.lock()

    guard detectionEnabled else {
      lock.unlock()
      return
    }

    // Adapt the floor only on quiet frames, so sustained speech cannot raise it to
    // the point where the speaker becomes inaudible to the detector.
    if level < noiseFloorDB {
      noiseFloorDB += (level - noiseFloorDB) * 0.5
    } else if !isActive {
      noiseFloorDB += (level - noiseFloorDB) * 0.002
    }

    let threshold = max(noiseFloorDB + tuning.speechMarginDB, tuning.absoluteThresholdDB)
    let now = Date()
    var transition: Bool?

    if level >= threshold {
      lastAboveThreshold = now
      framesAboveThreshold += 1
      if !isActive, framesAboveThreshold >= tuning.attackFrames {
        isActive = true
        transition = true
      }
    } else {
      framesAboveThreshold = 0
      if isActive, now.timeIntervalSince(lastAboveThreshold) >= tuning.releaseSeconds {
        isActive = false
        transition = false
      }
    }

    // Snapshot everything the caller needs while still holding the lock, then do the
    // actual work outside it — a sink that blocks must never block the tap's state.
    var sinksToCall: [@Sendable (AVAudioPCMBuffer) -> Void] = []
    if isActive {
      // Live audio goes to the recogniser; the ring is only for what came before.
      sinksToCall = Array(sinks.values)
    } else {
      retainForPreroll(buffer)
    }
    let handler = transition == nil ? nil : onActivity
    lock.unlock()

    for sink in sinksToCall { sink(buffer) }
    if let transition { handler?(transition, level) }
  }

  /// Caller must hold the lock.
  private func retainForPreroll(_ buffer: AVAudioPCMBuffer) {
    guard maxRingFrames > 0, let copy = Self.copy(buffer) else { return }
    ring.append(copy)
    ringFrames += copy.frameLength
    while ringFrames > maxRingFrames, !ring.isEmpty {
      ringFrames -= ring.removeFirst().frameLength
    }
  }

  // MARK: Helpers

  /// RMS in dBFS over the first channel. Cheap enough to run on every buffer.
  private static func levelDB(of buffer: AVAudioPCMBuffer) -> Float {
    guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return -100 }
    let samples = channels[0]
    let count = Int(buffer.frameLength)

    var sumOfSquares: Float = 0
    for index in 0..<count {
      let sample = samples[index]
      sumOfSquares += sample * sample
    }
    let mean = sumOfSquares / Float(count)
    guard mean > 0 else { return -100 }
    return max(-100, 10 * log10f(mean))
  }

  /// The buffer handed to a tap is owned by the engine and reused. Anything kept
  /// beyond the callback has to be a copy.
  private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(
      pcmFormat: buffer.format, frameCapacity: buffer.frameLength
    ) else { return nil }
    copy.frameLength = buffer.frameLength

    let channels = Int(buffer.format.channelCount)
    if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
      let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
      for channel in 0..<channels {
        memcpy(destination[channel], source[channel], bytes)
      }
      return copy
    }
    if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
      let bytes = Int(buffer.frameLength) * MemoryLayout<Int16>.size
      for channel in 0..<channels {
        memcpy(destination[channel], source[channel], bytes)
      }
      return copy
    }
    return nil
  }
}

// MARK: - Observer registry

/// Minimal multicast. Several components need the same events — the transcriber wants
/// voice activity, the controller wants interruptions — and `AsyncStream` only ever
/// has one consumer.
@MainActor
final class ObserverRegistry<Event> {

  private var handlers: [UUID: (Event) -> Void] = [:]

  @discardableResult
  func add(_ handler: @escaping (Event) -> Void) -> UUID {
    let id = UUID()
    handlers[id] = handler
    return id
  }

  func remove(_ id: UUID) {
    handlers.removeValue(forKey: id)
  }

  func removeAll() {
    handlers.removeAll()
  }

  func send(_ event: Event) {
    for handler in handlers.values { handler(event) }
  }
}

// MARK: - Speech authorisation

/// Wraps the completion-handler authorisation call so the pipeline can await it
/// without importing Speech's callback style into its own flow.
enum SFSpeechRecognizerAuthorizationHelper {
  static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
    SFSpeechRecognizer.requestAuthorization { status in
      completion(status == .authorized)
    }
  }
}
