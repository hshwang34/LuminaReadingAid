import SwiftUI

struct WordDetailView: View {
  @Bindable var word: CapturedWord
  @Environment(\.modelContext) private var modelContext
  @State private var isLookingUp = false
  @State private var lookupError: String?
  @State private var downloadProgress: Double?

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        // Word header
        VStack(spacing: Spacing.sm) {
          Text(word.text)
            .font(.display)
            .foregroundStyle(.ink)

          if let pronunciation = word.pronunciation {
            Text(pronunciation)
              .font(.title3)
              .italic()
              .foregroundStyle(.leather)
          }
        }

        // Part of speech + definition
        if let definition = word.definition {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("DEFINITION")
              .font(.caption)
              .textCase(.uppercase)
              .tracking(1.5)
              .foregroundStyle(.amber)

            Text(definition)
              .font(.body)
              .foregroundStyle(.ink)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Spacing.lg)
        }

        // Example
        if let example = word.exampleSentence {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("EXAMPLE")
              .font(.caption)
              .textCase(.uppercase)
              .tracking(1.5)
              .foregroundStyle(.amber)

            Text("\"\(example)\"")
              .font(.body)
              .italic()
              .foregroundStyle(.leather)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Spacing.lg)
        }

        // In context (original sentence from the book)
        if let context = word.contextPhrase,
           !context.isEmpty,
           context.lowercased() != word.text.lowercased() {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("IN CONTEXT")
              .font(.caption)
              .textCase(.uppercase)
              .tracking(1.5)
              .foregroundStyle(.amber)

            Text(highlightedContext(context, word: word.text))
              .font(.body)
              .italic()
              .foregroundStyle(.leather)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Spacing.lg)
        }

        // Source image
        if let imageData = word.imageData, let uiImage = UIImage(data: imageData) {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("CAPTURED IMAGE")
              .font(.caption)
              .textCase(.uppercase)
              .tracking(1.5)
              .foregroundStyle(.amber)
              .padding(.horizontal, Spacing.lg)

            Image(uiImage: uiImage)
              .resizable()
              .aspectRatio(contentMode: .fit)
              .frame(maxHeight: 200)
              .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
              .warmShadow()
              .padding(.horizontal, Spacing.lg)
          }
        }

        // Metadata
        VStack(alignment: .leading, spacing: Spacing.xs) {
          if let book = word.book {
            Label(book.title, systemImage: "book")
              .font(.subheadline)
              .foregroundStyle(.leather)
          }
          Label(word.capturedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
            .font(.subheadline)
            .foregroundStyle(.leather.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.lg)

        // Look up definition
        if word.definition == nil {
          VStack(spacing: Spacing.sm) {
            Button {
              Task { await lookUpDefinition() }
            } label: {
              VStack(spacing: Spacing.xs) {
                if let downloadProgress {
                  ProgressView(value: downloadProgress)
                    .tint(.amber)
                  Text("Downloading AI model\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.leather)
                } else if isLookingUp {
                  ProgressView()
                    .tint(.parchment)
                } else {
                  Label("Look Up Definition", systemImage: "brain")
                }
              }
              .frame(maxWidth: .infinity)
              .padding(Spacing.lg)
              .background(.ink, in: RoundedRectangle(cornerRadius: CornerRadius.button))
              .foregroundStyle(.parchment)
              .font(.headline)
            }
            .disabled(isLookingUp)

            if let lookupError {
              Text(lookupError)
                .font(.caption)
                .foregroundStyle(.brick)
            }
          }
          .padding(.horizontal, Spacing.lg)
        }
      }
      .padding(.vertical, Spacing.lg)
    }
    .background(.parchment)
    .navigationTitle(word.text)
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
