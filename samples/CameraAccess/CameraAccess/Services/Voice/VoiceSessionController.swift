//
// VoiceSessionController.swift
//
// The session. Everything the reader experiences as "Luna is on" is this state
// machine.
//
// It exists because the pieces underneath it are each simple and none of them knows
// what a reading session is: the pipeline knows about energy, the transcriber knows
// about text, the answer pipeline knows about one question. What turns those into a
// session is the ordering, the timeouts, and the decisions about when to stop
// listening — and those are worth having in one readable place rather than spread
// across three components.
//
// Two rules shape most of the code:
//
//  - Never deactivate the audio session in the background. A session that survives
//    the screen locking is the app's flagship behaviour, and deactivating while
//    locked ends it permanently with no way back in.
//
//  - Stop listening while Luna speaks. Her voice returns through the speaker, and
//    without echo cancellation the recogniser cannot tell it from the reader. v1
//    trades barge-in away for never answering its own question.
//

import AudioToolbox
import AVFoundation
import os
import Foundation
import Observation
import SwiftData
import UIKit
import UserNotifications

@MainActor
@Observable
final class VoiceSessionController {

  /// The running session, if any — how the Live Activity's End intent (which
  /// performs in this process but far from the view tree) reaches the session.
  /// Weak: the registry must never keep a dismissed session alive.
  private(set) static weak var active: VoiceSessionController?

  // MARK: - Phase

  enum Phase: Equatable {
    case idle
    /// Permissions, audio session, model. The only phase that requires the foreground.
    case startingUp
    /// Cheap steady state: energy detection only, waiting for the wake phrase.
    case listeningIdle
    /// Woke on "Hey Luna" with nothing after it — the reader is drawing breath.
    case awaitingQuestion
    /// Woke mid-sentence; the question is still arriving.
    case capturingUtterance
    case thinking
    case responding
    /// Follow-up window: the wake phrase is not required for a few seconds, so
    /// "and use it in a sentence" works the way a conversation does.
    case coolingDown
    case paused(PauseReason)
    case ended(EndReason)

    var isActive: Bool {
      switch self {
      case .idle, .ended: false
      default: true
      }
    }

    /// Whether the microphone is being listened to for the reader's benefit right now.
    var isListening: Bool {
      switch self {
      case .listeningIdle, .awaitingQuestion, .capturingUtterance, .coolingDown: true
      default: false
      }
    }
  }

  enum PauseReason: Equatable {
    case interruption
    case manual
  }

  enum EndReason: Equatable {
    case manual
    case silenceTimeout
    case failed(String)
  }

  // MARK: - Observable state

  private(set) var phase: Phase = .idle {
    didSet {
      guard oldValue != phase else { return }
      // The one line that reconstructs any session bug: every transition, in order.
      Log.session.info("phase \(String(describing: oldValue), privacy: .public) → \(String(describing: self.phase), privacy: .public)")
      updateLiveActivity()
    }
  }
  /// What the reader is saying right now, wake phrase stripped.
  private(set) var liveTranscript = ""
  private(set) var lastQuestion = ""
  /// The most recent spoken answer, verbatim — the model answers in prose now, so
  /// this string IS the answer, not a projection of structured fields.
  private(set) var lastAnswerText = ""
  /// Words captured in this session. Empty for now: capture left the answer path in
  /// the LM-native redesign and returns later as its own step behind the answer.
  private(set) var sessionWords: [String] = []
  private(set) var readiness: AnswerEngineReadiness = .notReady
  /// Non-fatal message worth putting in front of the reader.
  private(set) var banner: String?
  private(set) var startedAt: Date?
  /// End of the reader's speech to Luna's first sound, for the most recent question.
  private(set) var lastTimeToFirstAudio: TimeInterval?

  var book: Book?

  // MARK: - Dependencies

  private let modelContext: ModelContext
  private let pipeline: VoiceAudioPipeline
  private let transcriber: UtteranceTranscriber
  private let spotter: any WakeWordSpotting
  private let tts: TTSEngine
  private let answers: AnswerPipeline
  private let engine: AnswerEngine

  // MARK: - Internal state

  private var context = SessionContext()
  private var readingSession: ReadingSession?

  private var transcriberObserver: UUID?
  private var pipelineObserver: UUID?
  private var wakeTask: Task<Void, Never>?
  private var turnTask: Task<Void, Never>?
  private var modelTask: Task<Void, Never>?

  private var silenceTimer: Task<Void, Never>?
  private var windowTimer: Task<Void, Never>?

  private let liveActivity = VoiceSessionActivityManager()

  /// Set when the session ended in the background, where deactivating the audio
  /// session is forbidden. Settled on the next foregrounding.
  private var needsAudioDeactivation = false
  private var foregroundObserver: NSObjectProtocol?

  /// A session left running with nobody talking to it is a battery leak, so it ends
  /// itself. Fifteen minutes is long enough to cover a chapter without a question.
  private let silenceTimeout: TimeInterval = 15 * 60
  /// How long the follow-up window stays open after Luna finishes speaking.
  private let followUpWindow: TimeInterval = 5
  /// How long to wait for the question after a bare "Hey Luna".
  private let questionWindow: TimeInterval = 6

  // MARK: - Init

  init(
    modelContext: ModelContext,
    tts: TTSEngine? = nil,
    engine: AnswerEngine = LlamaAnswerEngine.shared
  ) {
    let pipeline = VoiceAudioPipeline()
    let transcriber = UtteranceTranscriber(pipeline: pipeline)
    let tts = tts ?? AVSpeechTTSEngine()

    self.modelContext = modelContext
    self.pipeline = pipeline
    self.transcriber = transcriber
    self.spotter = SFSpeechWakeWordSpotter(transcriber: transcriber)
    self.tts = tts
    self.engine = engine
    self.answers = AnswerPipeline(engine: engine, tts: tts, modelContext: modelContext)
  }

  // MARK: - Lifecycle

  /// Starts a session. Must be called from the foreground.
  func start(book: Book? = nil) async {
    guard !phase.isActive else { return }

    self.book = book
    phase = .startingUp
    banner = nil
    resetTurnState()
    context = SessionContext(bookTitle: book?.title)

    do {
      try await pipeline.start()
    } catch {
      phase = .ended(.failed(error.localizedDescription))
      return
    }

    observePipeline()
    observeTranscriber()
    transcriber.start()
    startWakeLoop()

    let session = ReadingSession(book: book)
    modelContext.insert(session)
    readingSession = session
    try? modelContext.save()
    startedAt = session.startedAt

    UIApplication.shared.isIdleTimerDisabled = true
    registerForegroundObserver()
    Self.active = self
    liveActivity.start(bookTitle: book?.title, startedAt: session.startedAt)

    // Listening starts immediately; the model loads behind it. A reader who starts a
    // session and speaks within a second should not be told to wait for a download
    // they never asked about — the wait, if there is one, happens once the question
    // actually needs the model.
    prepareModelIfNeeded()

    phase = .listeningIdle
    armSilenceTimeout()
  }

  func end(_ reason: EndReason = .manual) {
    guard phase.isActive else { return }

    cancelTimers()
    wakeTask?.cancel(); wakeTask = nil
    turnTask?.cancel(); turnTask = nil
    spotter.stopSpotting()
    transcriber.stop()
    tts.stop()

    if let transcriberObserver { transcriber.observers.remove(transcriberObserver) }
    if let pipelineObserver { pipeline.observers.remove(pipelineObserver) }
    transcriberObserver = nil
    pipelineObserver = nil

    // Deactivating the audio session from the background is the one thing that cannot
    // be undone without the reader unlocking the phone, so it waits.
    let isForeground = UIApplication.shared.applicationState == .active
    pipeline.stop(deactivateSession: isForeground)
    needsAudioDeactivation = !isForeground

    UIApplication.shared.isIdleTimerDisabled = false

    readingSession?.endedAt = Date()
    try? modelContext.save()

    // The observer outlives a background end on purpose: it is the only thing left
    // that can settle the deferred audio deactivation once the app is frontmost.
    if !needsAudioDeactivation {
      removeForegroundObserver()
    }
    clearPausedNotification()
    liveActivity.end(wordCount: sessionWords.count)
    if Self.active === self { Self.active = nil }
    phase = .ended(reason)
  }

  /// Reader-initiated pause, e.g. someone starts talking to them.
  func pauseManually() {
    guard phase.isListening || phase == .thinking || phase == .responding else { return }
    tts.stop()
    transcriber.pause()
    cancelTimers()
    phase = .paused(.manual)
  }

  func resume() {
    guard case .paused = phase else { return }
    banner = nil
    transcriber.resume()
    phase = .listeningIdle
    armSilenceTimeout()
  }

  /// Feed a question directly, bypassing the microphone. Used by the debug harness and
  /// by tests; the spoken path funnels into the same method.
  func ask(_ utterance: String) {
    runTurn(utterance)
  }

  // MARK: - Model

  private func prepareModelIfNeeded() {
    guard modelTask == nil else { return }
    modelTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await engine.prepare { state in
          Task { @MainActor in self.readiness = state }
        }
      } catch {
        readiness = .failed(error.localizedDescription)
        banner = "Luna can't answer yet: \(error.localizedDescription)"
      }
      modelTask = nil
    }
  }

  /// Blocks a turn until the model is usable, or gives up and says so.
  private func ensureModelReady() async -> Bool {
    // Ask the engine, not the mirrored copy. `readiness` here is only ever as fresh as
    // the last progress callback, so trusting it makes every turn depend on a
    // notification that a model loaded before this session began never sends.
    readiness = await engine.readiness
    if case .ready = readiness { return true }

    prepareModelIfNeeded()
    await modelTask?.value
    readiness = await engine.readiness
    if case .ready = readiness { return true }

    // Never fail a question in silence. Before this, a reader asking a question the
    // app had decided it could not answer got no speech, no error and no explanation.
    banner = switch readiness {
    case .downloading: "Luna is still downloading her language model."
    case .loading: "Luna is still waking up — ask again in a moment."
    case .failed(let message): "Luna can't answer: \(message)"
    default: "Luna isn't ready to answer yet."
    }
    return false
  }

  // MARK: - Observation

  private func observeTranscriber() {
    transcriberObserver = transcriber.observers.add { [weak self] event in
      self?.handleTranscriberEvent(event)
    }
  }

  private func observePipeline() {
    pipelineObserver = pipeline.observers.add { [weak self] event in
      self?.handlePipelineEvent(event)
    }
  }

  private func startWakeLoop() {
    wakeTask = Task { [weak self] in
      guard let self else { return }
      for await wake in spotter.startSpotting() {
        if Task.isCancelled { break }
        handleWake(wake)
      }
    }
  }

  // MARK: - Wake

  private func handleWake(_ wake: WakeEvent) {
    // Mid-answer wakes are ignored rather than queued: the reader cannot have heard
    // the answer yet, and the recogniser is not listening during playback anyway.
    switch phase {
    case .listeningIdle, .coolingDown:
      break
    default:
      return
    }

    armSilenceTimeout()
    Earcon.wake.play()
    liveTranscript = strippingWakeEcho(wake.trailingTranscript)
    phase = .capturingUtterance
    // Safety net, not a deadline: every partial re-arms it, so it only ever fires when
    // the burst-end event failed to arrive — without it, a missed event strands the
    // session in this phase with nothing to reset it.
    armWindow(questionWindow)
  }

  // MARK: - Transcript

  private func handleTranscriberEvent(_ event: UtteranceTranscriber.Event) {
    switch event {
    case .partial(let text):
      handlePartial(text)
    case .burstEnded(let text):
      handleBurstEnded(text)
    case .unavailable(let message):
      banner = message
      end(.failed(message))
    }
  }

  private func handlePartial(_ text: String) {
    switch phase {
    case .capturingUtterance:
      // Re-derive rather than remember an offset: partials get rewritten in place.
      liveTranscript = strippingWakeEcho(spotter.trailingUtterance(in: text) ?? text)
      armWindow(questionWindow)
    case .awaitingQuestion:
      liveTranscript = text
      // The reader is mid-question. Without this the window keeps ticking from when
      // it was armed, expires under their sentence, and the question they finish a
      // moment later lands in listeningIdle and is discarded — a wake, a perfect
      // transcription, and then nothing. A window's clock must only run in silence.
      armWindow(questionWindow)
    case .coolingDown:
      liveTranscript = text
      armWindow(followUpWindow)
    default:
      return
    }
    speculativelyPrefetch(liveTranscript)
  }

  private func handleBurstEnded(_ text: String) {
    switch phase {
    case .capturingUtterance:
      // Re-derive from the final text, but never *depend* on it. A recogniser rewrites
      // its transcript when the burst ends, and the rewrite can mangle the wake phrase
      // out of recognisability — "hey luna what does…" finalising as "Alina, what
      // does…". The wake already fired; failing to find its phrase again is not
      // grounds to throw the question away. The partial-derived transcript is the
      // fallback, and the raw text the last resort (the router's core patterns are
      // unanchored, so a stray "hey luna" prefix does not break them).
      let question = strippingWakeEcho(
        (spotter.trailingUtterance(in: text)
          ?? (liveTranscript.isEmpty ? text : liveTranscript))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      )

      if question.isEmpty {
        // "Hey Luna" and then a pause. Hold the door open rather than making them
        // say the phrase again.
        phase = .awaitingQuestion
        liveTranscript = ""
        armWindow(questionWindow)
      } else if !isCompleteEnoughToAnswer(question) {
        // Half a thought — the burst ended inside their hesitation. Keep listening;
        // the rest of the sentence is coming.
        Log.session.info("holding — fragment not answerable yet: \"\(question, privacy: .public)\"")
        phase = .awaitingQuestion
        armWindow(questionWindow)
      } else {
        runTurn(question)
      }

    case .awaitingQuestion:
      let question = strippingWakeEcho(text.trimmingCharacters(in: .whitespacesAndNewlines))
      guard !question.isEmpty else { return }
      guard isCompleteEnoughToAnswer(question) else {
        Log.session.info("holding — fragment not answerable yet: \"\(question, privacy: .public)\"")
        armWindow(questionWindow)
        return
      }
      cancelWindow()
      runTurn(question)

    case .coolingDown:
      let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
      // A short fragment during the follow-up window is usually room noise that the
      // recogniser turned into a word, not a question.
      guard question.split(separator: " ").count >= 2 else {
        Log.session.debug("follow-up fragment ignored: \"\(question, privacy: .public)\"")
        return
      }
      cancelWindow()
      runTurn(question)

    default:
      return
    }
  }

  /// Strips recogniser artifacts that trail the wake phrase.
  ///
  /// While the recogniser is still resolving "Luna" its partials read "Hey Luna Lu",
  /// and that stray "Lu" survives wake-phrase stripping to masquerade as the question.
  /// Leading fragments of the name (and stray trigger words) are dropped; anything
  /// left is the reader's.
  private func strippingWakeEcho(_ raw: String) -> String {
    var tokens = raw.split(separator: " ")
    while let first = tokens.first {
      let token = first.lowercased().trimmingCharacters(in: .punctuationCharacters)
      guard token == "hey" || (!token.isEmpty && "luna".hasPrefix(token)) else { break }
      tokens.removeFirst()
    }
    return tokens.joined(separator: " ")
  }

  /// Whether an utterance is worth a turn, or is half a thought still being formed.
  ///
  /// "Can you?" arrives as its own burst when the reader hesitates longer than the
  /// energy detector's patience, and answering half a thought talks over the rest of
  /// their sentence — the right response is to keep listening. A tiny keyword check
  /// stands in for completeness: short utterances that carry a lookup-ish word
  /// ("define grace") are complete; short ones that don't are a breath, not a
  /// question. Longer utterances always go to the model.
  private func isCompleteEnoughToAnswer(_ question: String) -> Bool {
    let tokens = question.lowercased().split(separator: " ")
    if tokens.count >= 4 { return true }
    let lookupWords: Set<String> = ["mean", "means", "meaning", "define", "definition",
                                    "explain", "pronounce", "say", "spell", "word"]
    return tokens.contains { lookupWords.contains(String($0)) }
  }

  /// Warm the dictionary while the reader is still talking.
  ///
  /// By the time the sentence ends, the definition for the word they are asking about
  /// is often already in memory, which removes a network round trip from the part of
  /// the budget the reader actually feels.
  private func speculativelyPrefetch(_ partial: String) {
    guard let word = IntentRouter.likelyTargetWord(in: partial) else { return }
    answers.prefetch(word)
  }

  // MARK: - Turn

  private func runTurn(_ utterance: String) {
    guard turnTask == nil else { return }

    Log.session.info("turn started: \"\(utterance, privacy: .public)\"")
    cancelWindow()
    armSilenceTimeout()
    lastQuestion = utterance
    liveTranscript = ""
    phase = .thinking

    // Stop listening before generation, not after: the first clause reaches the
    // speaker while the model is still writing the rest, so anything heard from here
    // on is Luna.
    transcriber.pause()

    turnTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.turnTask = nil
      }

      guard await ensureModelReady() else {
        Log.session.error("turn abandoned — model not ready (\(String(describing: self.readiness), privacy: .public))")
        finishTurnAndResumeListening()
        return
      }

      do {
        let result = try await answers.handle(
          utterance: utterance,
          context: context,
          onFirstAudio: { [weak self] in
            guard let self, self.phase == .thinking else { return }
            self.phase = .responding
          }
        )
        apply(result)
        await tts.finishSpeaking()
      } catch is CancellationError {
        Log.session.info("turn cancelled mid-answer")
      } catch {
        Log.session.error("turn failed: \(error.localizedDescription, privacy: .public)")
        banner = error.localizedDescription
      }

      finishTurnAndResumeListening()
    }
  }

  private func apply(_ result: AnswerPipeline.TurnResult) {
    context = result.context
    lastAnswerText = result.spokenText
    lastTimeToFirstAudio = result.timeToFirstAudio
    banner = nil
  }

  /// Reopen the microphone and hold the follow-up window open.
  private func finishTurnAndResumeListening() {
    guard phase.isActive, !isPausedOrEnded else { return }
    Earcon.readyForFollowUp.play()
    transcriber.resume()
    phase = .coolingDown
    armWindow(followUpWindow)
  }

  private var isPausedOrEnded: Bool {
    switch phase {
    case .paused, .ended, .idle: true
    default: false
    }
  }

  // MARK: - Audio events

  private func handlePipelineEvent(_ event: VoiceAudioPipeline.Event) {
    switch event {
    case .interrupted:
      turnTask?.cancel()
      turnTask = nil
      tts.stop()
      cancelTimers()
      banner = "Session paused — tap to resume."
      phase = .paused(.interruption)
      // With the phone locked there is no banner to see and no way to self-heal —
      // iOS will not hand the microphone back to a backgrounded app. A notification
      // is the only path back in: tapping it foregrounds the app, and the foreground
      // observer below restarts the audio.
      if UIApplication.shared.applicationState != .active {
        postPausedNotification()
      }

    case .interruptionEnded(let shouldResume):
      // Only self-heal in the foreground. From the lock screen the app cannot
      // reactivate the microphone, and pretending it resumed would be a lie the
      // reader only discovers when Luna fails to answer.
      guard shouldResume, UIApplication.shared.applicationState == .active else { return }
      Task { await restartAudioAfterInterruption() }

    case .routeChanged:
      banner = nil

    case .failed(let message):
      end(.failed(message))

    case .voiceBegan, .voiceEnded:
      break
    }
  }

  // MARK: - Live Activity

  /// Coarse phase → activity state. Thinking and responding both read as
  /// "answering" from a locked phone; the states a reader can act on are
  /// listening and paused.
  private func updateLiveActivity() {
    let label: String
    var paused = false
    switch phase {
    case .idle, .startingUp: label = "Starting"
    case .listeningIdle, .coolingDown: label = "Listening"
    case .awaitingQuestion, .capturingUtterance: label = "Listening"
    case .thinking: label = "Thinking"
    case .responding: label = "Speaking"
    case .paused:
      label = "Paused"
      paused = true
    case .ended: return  // end() renders the summary itself
    }
    liveActivity.update(phaseLabel: label, wordCount: sessionWords.count, isPaused: paused)
  }

  // MARK: - Foreground recovery

  private func registerForegroundObserver() {
    guard foregroundObserver == nil else { return }
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.handleWillEnterForeground() }
    }
  }

  private func removeForegroundObserver() {
    if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    foregroundObserver = nil
  }

  private func handleWillEnterForeground() {
    clearPausedNotification()

    // Settle the deactivation a background end had to defer.
    if needsAudioDeactivation {
      needsAudioDeactivation = false
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      Log.audio.info("deferred audio session deactivation settled on foreground")
      // If the session already ended, this observer only survived for that line.
      if case .ended = phase { removeForegroundObserver() }
    }

    // An interruption that ended while locked could not be resumed then — the
    // microphone is only grantable in the foreground, which is now.
    if case .paused(.interruption) = phase {
      Log.session.info("foregrounded while interruption-paused — attempting resume")
      Task { await restartAudioAfterInterruption() }
    }
  }

  // MARK: - Paused notification

  private static let pausedNotificationID = "luna.session.paused"

  /// "Session paused — tap to resume", delivered to the lock screen.
  ///
  /// Fire-and-forget on purpose: if notification permission was declined, the post
  /// silently does nothing, and the session is still recoverable by opening the app.
  private func postPausedNotification() {
    let content = UNMutableNotificationContent()
    content.title = "Reading session paused"
    content.body = "Something interrupted the microphone. Tap to resume your session."
    content.sound = nil  // the interruption itself was audible; don't pile on

    let request = UNNotificationRequest(
      identifier: Self.pausedNotificationID,
      content: content,
      trigger: nil  // deliver now
    )
    UNUserNotificationCenter.current().add(request)
    Log.session.info("posted session-paused notification")
  }

  private func clearPausedNotification() {
    let center = UNUserNotificationCenter.current()
    center.removeDeliveredNotifications(withIdentifiers: [Self.pausedNotificationID])
    center.removePendingNotificationRequests(withIdentifiers: [Self.pausedNotificationID])
  }

  private func restartAudioAfterInterruption() async {
    do {
      pipeline.stop(deactivateSession: false)
      try await pipeline.start()
      transcriber.start()
      banner = nil
      phase = .listeningIdle
      armSilenceTimeout()
    } catch {
      end(.failed(error.localizedDescription))
    }
  }

  // MARK: - Timers

  private func armSilenceTimeout() {
    silenceTimer?.cancel()
    silenceTimer = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: .seconds(silenceTimeout))
      guard !Task.isCancelled else { return }
      end(.silenceTimeout)
    }
  }

  private func armWindow(_ seconds: TimeInterval) {
    windowTimer?.cancel()
    windowTimer = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      switch phase {
      case .coolingDown, .awaitingQuestion, .capturingUtterance: break
      default: return
      }
      // Same rule, enforced at the point of expiry: partials re-arm this timer, but a
      // partial can lag the sound itself, so the energy detector is the authority. If
      // someone is audibly talking, give them the window again rather than closing it
      // over their sentence.
      if pipeline.isVoiceActive {
        armWindow(seconds)
        return
      }
      liveTranscript = ""
      phase = .listeningIdle
    }
  }

  private func cancelWindow() {
    windowTimer?.cancel()
    windowTimer = nil
  }

  private func cancelTimers() {
    silenceTimer?.cancel(); silenceTimer = nil
    cancelWindow()
  }

  private func resetTurnState() {
    liveTranscript = ""
    lastQuestion = ""
    lastAnswerText = ""
    lastTimeToFirstAudio = nil
    sessionWords = []
  }
}

// MARK: - Earcons

/// The short tones that tell the reader the state changed without them having to look.
///
/// They matter more than they sound like they should: there is roughly a second
/// between the end of a question and Luna's first word, and in that second a silent
/// phone is indistinguishable from a broken one.
enum Earcon {
  case wake
  case readyForFollowUp

  private var soundID: SystemSoundID {
    switch self {
    case .wake: 1113            // the system "begin recording" tone
    case .readyForFollowUp: 1114 // "end recording"
    }
  }

  func play() {
    AudioServicesPlaySystemSound(soundID)
  }
}
