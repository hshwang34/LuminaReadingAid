//
// SessionTabView.swift
//
// The app's front door. There is no "start" button anywhere: being on this tab
// IS the session. The app opens listening, the reader keeps their eyes on the
// book, and the screen splits into two registers — the edge glow carries the
// conversation's state ambiently, the definition card carries the information
// formally. (Successor to the fullScreenCover-era VoiceSessionView.)
//
// The controller is owned by MainAppView, not this view, so the session's
// lifetime is the app's lifetime — switching tabs never touches the microphone.
//

import SwiftData
import SwiftUI

struct SessionTabView: View {

  let controller: VoiceSessionController

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage(OnboardingViewModel.hasCompletedKey) private var hasCompletedOnboarding = false

  /// The books the picker offers — what the reader is currently in the middle of.
  @Query(filter: #Predicate<Book> { !$0.isFinished }, sort: \Book.dateAdded, order: .reverse)
  private var readingBooks: [Book]

  @State private var elapsed: TimeInterval = 0
  @State private var showBookLink = false

  private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    NavigationStack {
      ZStack {
        Color.parchment.ignoresSafeArea()

        EdgeGlowView(phase: controller.phase, reduceMotion: reduceMotion)

        content
      }
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Text(elapsedText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.leather)
        }
        if controller.phase.isActive {
          ToolbarItem(placement: .topBarTrailing) {
            Button("End") { controller.end(.manual) }
              .font(.headline)
              .foregroundStyle(.ink)
          }
        }
      }
    }
    .task(id: hasCompletedOnboarding) {
      await autoStartIfNeeded()
    }
    .onChange(of: scenePhase) { _, newPhase in
      // Open app = listening. A session that auto-ended overnight restarts the
      // moment the reader comes back; one they ended by hand also restarts on the
      // next entry, because entering the app is the ask.
      guard newPhase == .active else { return }
      Task { await autoStartIfNeeded() }
    }
    .onReceive(ticker) { _ in
      guard controller.phase.isActive, let startedAt = controller.startedAt else { return }
      elapsed = Date().timeIntervalSince(startedAt)
    }
    .onChange(of: controller.phase) { _, phase in
      guard case .ended = phase, controller.needsBookLink else { return }
      showBookLink = true
    }
    .sheet(isPresented: $showBookLink) {
      if let session = controller.readingSession {
        OrphanSessionLinkView(session: session) {
          showBookLink = false
        }
      }
    }
  }

  private func autoStartIfNeeded() async {
    guard hasCompletedOnboarding, !showBookLink else { return }
    guard !controller.phase.isActive else { return }
    await controller.start(book: nil)
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    switch controller.phase {
    case .ended(.failed(let message)):
      failedState(message)
    case .ended:
      summaryState
    default:
      liveState
    }
  }

  private var liveState: some View {
    VStack(spacing: 0) {
      header

      Spacer(minLength: Spacing.lg)

      VStack(spacing: Spacing.xl) {
        Text(statusLine(for: controller.phase))
          .font(.subheadline)
          .foregroundStyle(.leather)
          .multilineTextAlignment(.center)
          .transition(.opacity)

        if !controller.liveTranscript.isEmpty {
          QuillUnderlinedText(text: controller.liveTranscript, reduceMotion: reduceMotion)
            .padding(.horizontal, Spacing.xl)
        }

        if !controller.lastAnswerText.isEmpty {
          answerCard
            .padding(.horizontal, Spacing.lg)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
      }
      .animation(.spring(duration: 0.3), value: controller.phase)
      .animation(.spring(duration: 0.3), value: controller.lastAnswerText)

      Spacer(minLength: Spacing.lg)

      footer

      #if DEBUG
      debugReadout
      #endif
    }
    .padding(.vertical, Spacing.lg)
  }

  /// Formal when the turn resolved to a word, prose when it didn't. The formal
  /// card can upgrade mid-answer — capture runs while Luna is still speaking.
  @ViewBuilder
  private var answerCard: some View {
    if let word = controller.lastCapturedWord {
      FormalDefinitionCard(
        word: word,
        question: controller.lastQuestion,
        spokenAnswer: controller.lastAnswerText
      )
    } else {
      SessionAnswerCard(question: controller.lastQuestion, answer: controller.lastAnswerText)
    }
  }

  // MARK: - Header (book picker)

  private var header: some View {
    VStack(spacing: Spacing.sm) {
      if let banner = controller.banner {
        SessionBanner(message: banner, isPaused: isPaused(controller.phase)) {
          controller.resume()
        }
        .padding(.horizontal, Spacing.lg)
      }

      // The book is a detail the reader fills in when they feel like it — by
      // tapping here, or never (the end-of-session link sheet catches strays).
      Menu {
        ForEach(readingBooks) { book in
          Button {
            controller.bind(book: book)
          } label: {
            if book === controller.book {
              Label(book.title, systemImage: "checkmark")
            } else {
              Text(book.title)
            }
          }
        }
        if controller.book != nil {
          Divider()
          Button("No book") { controller.bind(book: nil) }
        }
      } label: {
        HStack(spacing: Spacing.xs) {
          Text(controller.book?.title ?? "Choose a book")
            .font(.headline)
            .foregroundStyle(controller.book == nil ? .leather : .ink)
            .lineLimit(1)
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption2)
            .foregroundStyle(.leather)
        }
      }
      .disabled(!controller.phase.isActive)

      Text(wordCountText(controller.sessionWords.count))
        .font(.caption)
        .foregroundStyle(.leather.opacity(0.7))
    }
  }

  private var footer: some View {
    VStack(spacing: Spacing.lg) {
      if !controller.sessionWords.isEmpty {
        SessionWordChips(words: controller.sessionWords)
      }

      Label("You can lock your phone — Luna keeps listening.", systemImage: "lock")
        .font(.caption)
        .foregroundStyle(.leather.opacity(0.7))
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.xl)
    }
  }

  // MARK: - Ended states

  /// Ending a session gets a payoff moment, not a vanishing screen.
  private var summaryState: some View {
    VStack(spacing: Spacing.xl) {
      Spacer()

      VStack(spacing: Spacing.sm) {
        Text("Nice reading")
          .font(.screenTitle)
          .foregroundStyle(.ink)
        if let title = controller.book?.title {
          Text(title)
            .font(.subheadline)
            .foregroundStyle(.leather)
        }
      }

      HStack(spacing: Spacing.xl) {
        summaryStat(value: elapsedText, label: "time")
        summaryStat(value: "\(controller.sessionWords.count)", label: controller.sessionWords.count == 1 ? "word" : "words")
      }

      if !controller.sessionWords.isEmpty {
        SessionWordChips(words: controller.sessionWords)
      }

      Spacer()

      Button {
        Task { await controller.start(book: nil) }
      } label: {
        Text("Start Again")
          .font(.headline)
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .padding(Spacing.lg)
          .background(.amber, in: RoundedRectangle(cornerRadius: CornerRadius.button))
      }
      .padding(.horizontal, Spacing.lg)
    }
    .padding(.vertical, Spacing.lg)
  }

  private func summaryStat(value: String, label: String) -> some View {
    VStack(spacing: 2) {
      Text(value)
        .font(.stat(24))
        .foregroundStyle(.ink)
      Text(label)
        .font(.caption)
        .foregroundStyle(.leather)
    }
  }

  /// The one state that needs the reader's hands: the microphone was refused, or
  /// audio failed outright. Never silent — say what happened and what fixes it.
  private func failedState(_ message: String) -> some View {
    VStack(spacing: Spacing.lg) {
      Spacer()

      Image(systemName: "mic.slash")
        .font(.system(size: 44))
        .foregroundStyle(.leather.opacity(0.5))

      Text("Luna can't listen right now")
        .font(.sectionTitle)
        .foregroundStyle(.ink)

      Text(message)
        .font(.subheadline)
        .foregroundStyle(.leather)
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.xl)

      Spacer()

      VStack(spacing: Spacing.md) {
        Button {
          Task { await controller.start(book: nil) }
        } label: {
          Text("Try Again")
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(Spacing.lg)
            .background(.amber, in: RoundedRectangle(cornerRadius: CornerRadius.button))
        }

        Button {
          if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
          }
        } label: {
          Text("Open Settings")
            .font(.headline)
            .foregroundStyle(.ink)
            .frame(maxWidth: .infinity)
            .padding(Spacing.lg)
            .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.button))
            .overlay(RoundedRectangle(cornerRadius: CornerRadius.button).strokeBorder(.hairline, lineWidth: 1))
        }
      }
      .padding(.horizontal, Spacing.lg)
    }
    .padding(.vertical, Spacing.lg)
  }

  #if DEBUG
  /// The session's internal state, on screen — which phase a silent failure
  /// stalled in is the single most useful fact, and it is invisible otherwise.
  private var debugReadout: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("phase: \(String(describing: controller.phase))")
      Text("model: \(String(describing: controller.readiness))")
      if let ttfa = controller.lastTimeToFirstAudio {
        Text("first audio: \(Int(ttfa * 1000)) ms")
      }
      if !controller.lastQuestion.isEmpty {
        Text("heard: \(controller.lastQuestion)")
      }

      HStack(spacing: Spacing.sm) {
        Text("hold \(String(format: "%.1f", controller.vadTuning.releaseSeconds))s")
          .frame(width: 64, alignment: .leading)
        Slider(
          value: Binding(
            get: { controller.vadTuning.releaseSeconds },
            set: { controller.vadTuning.releaseSeconds = $0 }
          ),
          in: 0.5...2.5, step: 0.1
        )
      }
      HStack(spacing: Spacing.sm) {
        Text("margin \(Int(controller.vadTuning.speechMarginDB))dB")
          .frame(width: 64, alignment: .leading)
        Slider(
          value: Binding(
            get: { Double(controller.vadTuning.speechMarginDB) },
            set: { controller.vadTuning.speechMarginDB = Float($0) }
          ),
          in: 3...20, step: 1
        )
      }
    }
    .font(.caption2.monospaced())
    .foregroundStyle(.leather.opacity(0.6))
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Spacing.lg)
  }
  #endif

  // MARK: - Helpers

  private func isPaused(_ phase: VoiceSessionController.Phase) -> Bool {
    if case .paused = phase { return true }
    return false
  }

  private var elapsedText: String {
    let total = Int(elapsed)
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  private func wordCountText(_ count: Int) -> String {
    switch count {
    case 0: "No words yet"
    case 1: "1 word this session"
    default: "\(count) words this session"
    }
  }

  private func statusLine(for phase: VoiceSessionController.Phase) -> String {
    switch phase {
    case .idle, .startingUp: "Waking Luna up…"
    case .listeningIdle: "Say “Hey Luna” anytime"
    case .awaitingQuestion: "I'm listening…"
    case .capturingUtterance: ""
    case .thinking: ""
    case .responding: ""
    case .coolingDown: "Ask a follow-up, or keep reading"
    case .paused(.manual): "Paused"
    case .paused(.interruption): "Paused — tap resume when you're ready"
    case .ended: "Session ended"
    }
  }
}
