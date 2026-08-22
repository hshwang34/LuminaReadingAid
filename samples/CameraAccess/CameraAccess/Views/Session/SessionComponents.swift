//
// SessionComponents.swift
//
// The session screen's small parts, shared between the live tab and (eventually)
// the voice practice mode. Moved here from the retired VoiceSessionView.
//

import SwiftUI

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

// MARK: - Answer cards

/// Luna's answer as a dictionary entry — the formal face of the session screen.
/// The voice conversation stays ambient (the edge glow); what the screen shows is
/// the thing worth reading off: the word, its pronunciation, ONE gloss that fits
/// the book, and the sentence that asked. Density lives behind the disclosure.
struct FormalDefinitionCard: View {

  let word: CapturedWord
  let question: String
  let spokenAnswer: String

  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(word.text)
        .font(.headword)
        .foregroundStyle(.ink)

      if let pronunciation = word.pronunciation, !pronunciation.isEmpty {
        Text(pronunciation)
          .font(.subheadline)
          .italic()
          .foregroundStyle(.leather)
      }

      if let pos = word.displayPartOfSpeech {
        Text(pos.uppercased())
          .font(.caption2.weight(.semibold))
          .tracking(1.2)
          .foregroundStyle(.amber)
          .padding(.top, Spacing.xs)
      }

      if let gloss = word.bareDefinition, !gloss.isEmpty {
        Text(gloss)
          .font(.body)
          .foregroundStyle(.ink)
          .padding(.top, Spacing.xs)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !question.isEmpty {
        Text("“\(question)”")
          .font(.footnote)
          .italic()
          .foregroundStyle(.leather)
          .padding(.top, Spacing.xs)
      }

      Button {
        withAnimation(.spring(duration: 0.3)) { expanded.toggle() }
      } label: {
        HStack(spacing: Spacing.xs) {
          Text(expanded ? "Less" : "Full definition")
          Image(systemName: "chevron.right")
            .font(.caption2)
            .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.leather)
      }
      .padding(.top, Spacing.sm)

      if expanded {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          Divider().overlay(.hairline)

          // What Luna actually said — the conversational answer, kept off the
          // formal face on purpose.
          Text(spokenAnswer)
            .font(.subheadline)
            .foregroundStyle(.ink)
            .fixedSize(horizontal: false, vertical: true)

          if let example = word.exampleSentence, !example.isEmpty {
            Text(example)
              .font(.subheadline)
              .italic()
              .foregroundStyle(.leather)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.lg)
    .hairlineCard()
  }
}

/// The prose fallback: a question that didn't resolve to a captured word still
/// deserves its answer on screen.
struct SessionAnswerCard: View {

  let question: String
  let answer: String

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      if !question.isEmpty {
        Text(question)
          .font(.caption)
          .italic()
          .foregroundStyle(.leather)
      }

      Text(answer)
        .font(.body)
        .foregroundStyle(.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.lg)
    .hairlineCard()
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
            .overlay(Capsule().strokeBorder(.hairline, lineWidth: 1))
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
          .foregroundStyle(.amber)
      }
    }
    .padding(Spacing.md)
    .hairlineCard()
  }
}
