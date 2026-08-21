//
// VoiceSessionView.swift
//
// The screen a reader looks at least and relies on most.
//
// A voice session is meant to be used with the phone face down beside a book, so this
// view's job is not to be interacted with — it is to make the invisible legible. At a
// glance it has to answer: is Luna listening, did she hear me, what did she say, and
// what have I collected so far. Everything else is deliberately absent.
//
// The visual language follows DESIGN_SYSTEM.md rather than the usual voice-assistant
// vocabulary: no waveform, no pulsing neon ring. A single ink dot that blooms while
// listening, an amber underline that draws itself beneath live speech, and pen-tap
// dots while thinking. It should read as a fountain pen resting on paper.
//

import SwiftData
import SwiftUI

struct VoiceSessionView: View {

  let book: Book?

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var controller: VoiceSessionController?
  @State private var elapsed: TimeInterval = 0

  private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    NavigationStack {
      ZStack {
        Color.parchment.ignoresSafeArea()

        if let controller {
          content(controller)
        } else {
          ProgressView().tint(.leather)
        }
      }
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Text(elapsedText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.leather)
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("End") { endSession() }
            .font(.headline)
            .foregroundStyle(.ink)
        }
      }
    }
    .task {
      guard controller == nil else { return }
      let created = VoiceSessionController(modelContext: modelContext)
      controller = created
      await created.start(book: book)
    }
    .onReceive(ticker) { _ in
      guard let startedAt = controller?.startedAt else { return }
      elapsed = Date().timeIntervalSince(startedAt)
    }
    .onChange(of: controller?.phase) { _, phase in
      if case .ended = phase { dismiss() }
    }
    .interactiveDismissDisabled()
  }

  // MARK: - Content

  @ViewBuilder
  private func content(_ controller: VoiceSessionController) -> some View {
    VStack(spacing: 0) {
      header(controller)

      Spacer(minLength: Spacing.lg)

      VStack(spacing: Spacing.xl) {
        ListeningIndicator(phase: controller.phase, reduceMotion: reduceMotion)

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
          SessionAnswerCard(question: controller.lastQuestion, answer: controller.lastAnswerText)
            .padding(.horizontal, Spacing.lg)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
      }
      .animation(.spring(duration: 0.3), value: controller.phase)
      .animation(.spring(duration: 0.3), value: controller.lastAnswerText)

      Spacer(minLength: Spacing.lg)

      footer(controller)

      #if DEBUG
      debugReadout(controller)
      #endif
    }
    .padding(.vertical, Spacing.lg)
  }

  #if DEBUG
  /// The session's internal state, on screen.
  ///
  /// A voice session fails quietly by nature — nothing was spoken, and there is no
  /// screen the reader was looking at to show an error on. Which phase it stalled in
  /// is the single most useful fact when that happens, and it is invisible otherwise.
  private func debugReadout(_ controller: VoiceSessionController) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("phase: \(String(describing: controller.phase))")
      Text("model: \(String(describing: controller.readiness))")
      if let ttfa = controller.lastTimeToFirstAudio {
        Text("first audio: \(Int(ttfa * 1000)) ms")
      }
      if !controller.lastQuestion.isEmpty {
        Text("heard: \(controller.lastQuestion)")
      }
    }
    .font(.caption2.monospaced())
    .foregroundStyle(.leather.opacity(0.6))
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Spacing.lg)
  }
  #endif

  private func header(_ controller: VoiceSessionController) -> some View {
    VStack(spacing: Spacing.sm) {
      if let banner = controller.banner {
        SessionBanner(message: banner, isPaused: isPaused(controller.phase)) {
          controller.resume()
        }
        .padding(.horizontal, Spacing.lg)
      }

      Text(book?.title ?? "Reading session")
        .font(.serif(.title3, weight: .semibold))
        .foregroundStyle(.ink)
        .lineLimit(1)

      Text(wordCountText(controller.sessionWords.count))
        .font(.caption)
        .foregroundStyle(.leather.opacity(0.7))
    }
  }

  private func footer(_ controller: VoiceSessionController) -> some View {
    VStack(spacing: Spacing.lg) {
      if !controller.sessionWords.isEmpty {
        SessionWordChips(words: controller.sessionWords)
      }

      Label("You can lock your phone — Luna keeps listening.", systemImage: "lock")
        .font(.caption)
        .foregroundStyle(.leather.opacity(0.7))
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.xl)

      Button {
        endSession()
      } label: {
        Text("End Session")
          .font(.headline)
          .foregroundStyle(.ink)
          .frame(maxWidth: .infinity)
          .padding(Spacing.lg)
          .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.button))
      }
      .padding(.horizontal, Spacing.lg)
    }
  }

  // MARK: - Helpers

  private func endSession() {
    controller?.end(.manual)
    dismiss()
  }

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

// MARK: - Listening indicator

/// The ink dot. Blooms while listening, taps like a pen while thinking, shimmers
/// while speaking.
struct ListeningIndicator: View {

  let phase: VoiceSessionController.Phase
  let reduceMotion: Bool

  @State private var bloom = false

  var body: some View {
    Group {
      switch phase {
      case .thinking:
        HStack(spacing: Spacing.sm) {
          ForEach(0..<3, id: \.self) { index in
            Circle()
              .fill(.leather)
              .frame(width: 8, height: 8)
              .opacity(bloom ? 1 : 0.3)
              .animation(
                reduceMotion
                  ? .none
                  : .easeInOut(duration: 0.45).repeatForever().delay(Double(index) * 0.15),
                value: bloom
              )
          }
        }
        .frame(height: 44)

      case .responding:
        Circle()
          .fill(.amber)
          .frame(width: 14, height: 14)
          .overlay {
            Circle()
              .stroke(.amber.opacity(0.35), lineWidth: 8)
              .scaleEffect(bloom ? 2.4 : 1.2)
              .opacity(bloom ? 0 : 0.8)
              .animation(
                reduceMotion ? .none : .easeOut(duration: 1.2).repeatForever(autoreverses: false),
                value: bloom
              )
          }
          .frame(height: 44)

      default:
        Circle()
          .fill(.ink)
          .frame(width: 12, height: 12)
          .scaleEffect(scale)
          .overlay {
            Circle()
              .fill(.amber.opacity(0.15))
              .frame(width: 44, height: 44)
              .scaleEffect(bloom ? 1.0 : 0.7)
              .opacity(phase.isListening ? 1 : 0)
          }
          .animation(
            reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 3).repeatForever(),
            value: bloom
          )
          .frame(height: 44)
      }
    }
    .onAppear { bloom = true }
  }

  private var scale: CGFloat {
    guard phase.isListening, !reduceMotion else { return 1 }
    return bloom ? 1.18 : 1.0
  }
}

// MARK: - Live transcript

/// The reader's own words, underlined as if drawn with a quill.
struct QuillUnderlinedText: View {

  let text: String
  let reduceMotion: Bool

  @State private var progress: CGFloat = 0

  var body: some View {
    Text(text)
      .font(.serif(.title3))
      .italic()
      .foregroundStyle(.leather)
      .multilineTextAlignment(.center)
      .overlay(alignment: .bottom) {
        QuillLine()
          .trim(from: 0, to: progress)
          .stroke(.amber, style: StrokeStyle(lineWidth: 2, lineCap: .round))
          .frame(height: 6)
          .offset(y: 6)
      }
      .onChange(of: text) { _, _ in redraw() }
      .onAppear { redraw() }
  }

  private func redraw() {
    progress = 0
    withAnimation(reduceMotion ? .none : .easeOut(duration: 0.4)) { progress = 1 }
  }
}

/// A slightly uneven line — a ruler-straight underline reads as a text field, which is
/// the one thing this screen is not.
private struct QuillLine: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.midY))
    path.addCurve(
      to: CGPoint(x: rect.maxX, y: rect.midY),
      control1: CGPoint(x: rect.width * 0.33, y: rect.midY - 2.5),
      control2: CGPoint(x: rect.width * 0.66, y: rect.midY + 2.5)
    )
    return path
  }
}

// MARK: - Answer card

/// Luna's answer, as she spoke it. The model answers in prose, so the card shows
/// prose — the reader's question in the margin voice, the answer as the body.
struct SessionAnswerCard: View {

  let question: String
  let answer: String

  var body: some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(.amber)
        .frame(width: 3)

      VStack(alignment: .leading, spacing: Spacing.sm) {
        if !question.isEmpty {
          Text(question)
            .font(.caption)
            .italic()
            .foregroundStyle(.leather)
        }

        Text(answer)
          .font(.serif(.body))
          .foregroundStyle(.ink)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.lg)
    }
    .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
    .warmShadow(.subtle)
  }
}

// MARK: - Word chips

struct SessionWordChips: View {
  let words: [String]

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.sm) {
        ForEach(words, id: \.self) { word in
          Text(word)
            .font(.subheadline)
            .foregroundStyle(.ink)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(.linen, in: Capsule())
        }
      }
      .padding(.horizontal, Spacing.lg)
    }
  }
}

// MARK: - Banner

struct SessionBanner: View {
  let message: String
  let isPaused: Bool
  let onResume: () -> Void

  var body: some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: isPaused ? "mic.slash" : "exclamationmark.triangle")
        .foregroundStyle(isPaused ? .brick : .amber)
      Text(message)
        .font(.caption)
        .foregroundStyle(.ink)
      Spacer()
      if isPaused {
        Button("Resume", action: onResume)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.ink)
      }
    }
    .padding(Spacing.md)
    .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(isPaused ? .brick : .amber)
        .frame(width: 3)
    }
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
  }
}
