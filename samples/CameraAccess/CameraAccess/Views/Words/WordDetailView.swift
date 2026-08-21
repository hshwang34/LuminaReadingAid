import SwiftUI

//
// WordDetailView.swift
//
// The anti-density screen. A reader reviewing a word wants the one definition
// that fit their book — not a dictionary page. So the first screen is: the word,
// how to say it, ONE gloss, and the sentence it came from. Every other sense,
// the example, the source image, and the metadata live behind an explicit
// "Full definition" disclosure.
//

struct WordDetailView: View {
  @Bindable var word: CapturedWord
  @Environment(\.modelContext) private var modelContext
  @State private var isLookingUp = false
  @State private var lookupError: String?
  @State private var downloadProgress: Double?
  @State private var expanded = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        // Headword — the one place serif belongs.
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(word.text)
            .font(.headword)
            .foregroundStyle(.ink)

          if let pronunciation = word.pronunciation {
            Text(pronunciation)
              .font(.title3)
              .italic()
              .foregroundStyle(.leather)
          }
        }

        // Mastery, at a glance.
        HStack(spacing: Spacing.sm) {
          MasteryBar(level: word.masteryLevel)
          Text(masteryLabel)
            .font(.caption)
            .foregroundStyle(.leather)
        }

        // The one gloss. No eyebrow label — it is the only thing here.
        if let definition = word.definition {
          Text(definition)
            .font(.title3)
            .foregroundStyle(.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Spacing.xs)
        }

        // The sentence that asked.
        if let context = word.contextPhrase,
           !context.isEmpty,
           context.lowercased() != word.text.lowercased() {
          Text(highlightedContext(context, word: word.text))
            .font(.body)
            .italic()
            .foregroundStyle(.leather)
            .fixedSize(horizontal: false, vertical: true)
        }

        if word.definition != nil {
          disclosure
        }

        if word.definition == nil {
          lookupSection
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.lg)
    }
    .background(.parchment)
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          word.isStarred.toggle()
          try? modelContext.save()
        } label: {
          Image(systemName: word.isStarred ? "star.fill" : "star")
            .foregroundStyle(word.isStarred ? .amber : .leather)
        }
      }
    }
  }

  // MARK: - Full definition disclosure

  private var disclosure: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Button {
        withAnimation(.spring(duration: 0.3)) { expanded.toggle() }
      } label: {
        HStack(spacing: Spacing.xs) {
          Text(expanded ? "Less" : "Full definition")
          Image(systemName: "chevron.right")
            .font(.caption2)
            .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.amber)
      }

      if expanded {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          if let example = word.exampleSentence {
            labeledBlock("Example") {
              Text("\u{201C}\(example)\u{201D}")
                .font(.body)
                .italic()
                .foregroundStyle(.leather)
            }
          }

          if let imageData = word.imageData, let uiImage = UIImage(data: imageData) {
            labeledBlock("Captured image") {
              Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
            }
          }

          labeledBlock("Details") {
            VStack(alignment: .leading, spacing: Spacing.xs) {
              if let book = word.book {
                Label(book.title, systemImage: "book")
              }
              Label(word.capturedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
              if let spoken = word.spokenUtterance, !spoken.isEmpty {
                Label("Asked as \u{201C}\(spoken)\u{201D}", systemImage: "waveform")
              }
            }
            .font(.subheadline)
            .foregroundStyle(.leather)
          }
        }
        .transition(.opacity)
      }
    }
    .padding(.top, Spacing.sm)
  }

  private func labeledBlock(_ label: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label.uppercased())
        .font(.caption2.weight(.semibold))
        .tracking(1.2)
        .foregroundStyle(.leather.opacity(0.7))
      content()
    }
  }

  private var masteryLabel: String {
    switch word.masteryLevel {
    case 0: "New"
    case 1...2: "Learning"
    case 3...4: "Familiar"
    default: "Known"
    }
  }

  // MARK: - Look up

  private var lookupSection: some View {
    VStack(spacing: Spacing.sm) {
      Button {
        Task { await lookUpDefinition() }
      } label: {
        VStack(spacing: Spacing.xs) {
          if let downloadProgress {
            ProgressView(value: downloadProgress)
              .tint(.white)
            Text("Downloading AI model\u{2026}")
              .font(.caption)
          } else if isLookingUp {
            ProgressView()
              .tint(.white)
          } else {
            Label("Look Up Definition", systemImage: "brain")
          }
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.lg)
        .background(.amber, in: RoundedRectangle(cornerRadius: CornerRadius.button))
        .foregroundStyle(.white)
        .font(.headline)
      }
      .disabled(isLookingUp)

      if let lookupError {
        Text(lookupError)
          .font(.caption)
          .foregroundStyle(.brick)
      }
    }
    .padding(.top, Spacing.md)
  }

  /// Returns an AttributedString with the target word bolded (and in ink color)
  /// wherever it appears in the context phrase. Case-insensitive match.
  private func highlightedContext(_ context: String, word: String) -> AttributedString {
    var attributed = AttributedString(context)
    guard !word.isEmpty else { return attributed }

    var searchRange = attributed.startIndex..<attributed.endIndex
    while let match = attributed[searchRange].range(of: word, options: .caseInsensitive) {
      attributed[match].font = .body.weight(.bold)
      attributed[match].foregroundColor = .ink
      searchRange = match.upperBound..<attributed.endIndex
    }
    return attributed
  }

  private func lookUpDefinition() async {
    isLookingUp = true
    lookupError = nil
    do {
      // Try on-device LLM first
      try await OnDeviceLLMService.shared.ensureModelLoaded { progress in
        Task { @MainActor in self.downloadProgress = progress }
      }
      downloadProgress = nil
      let result = try await OnDeviceLLMService.shared.generateDefinition(
        word: word.text,
        bookTitle: word.book?.title
      )
      word.definition = result.definition
      word.pronunciation = result.pronunciation.isEmpty ? nil : result.pronunciation
      word.exampleSentence = result.exampleSentence.isEmpty ? nil : result.exampleSentence
      try? modelContext.save()
    } catch {
      // Fallback to dictionary API
      do {
        let result = try await DefinitionService().lookUp(word: word.text)
        word.definition = result.definition
        word.pronunciation = result.pronunciation.isEmpty ? nil : result.pronunciation
        word.exampleSentence = result.exampleSentence.isEmpty ? nil : result.exampleSentence
        try? modelContext.save()
      } catch {
        lookupError = error.localizedDescription
      }
    }
    isLookingUp = false
  }
}

// MARK: - Mastery bar

/// Five amber segments, one per level above zero — the same visual language as
/// the mastery dots in book word lists and the histogram in Profile.
struct MasteryBar: View {
  let level: Int

  var body: some View {
    HStack(spacing: 3) {
      ForEach(1...5, id: \.self) { step in
        RoundedRectangle(cornerRadius: 2)
          .fill(step <= level ? .amber : .linen)
          .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.hairline, lineWidth: 0.5))
          .frame(width: 16, height: 5)
      }
    }
    .accessibilityLabel("Mastery level \(level) of 5")
  }
}
