import SwiftUI
import SwiftData

struct WordsTabView: View {
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \CapturedWord.capturedAt, order: .reverse) private var words: [CapturedWord]
  @State private var searchText = ""
  @State private var filter: WordFilter = .all
  @State private var editMode: EditMode = .inactive
  @State private var selection = Set<PersistentIdentifier>()
  @State private var showDeleteAllConfirm = false
  @State private var showDeleteSelectedConfirm = false

  enum WordFilter: String, CaseIterable {
    case all = "All"
    case starred = "Starred"
  }

  private var filteredWords: [CapturedWord] {
    var result = words
    if !searchText.isEmpty {
      result = result.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }
    switch filter {
    case .all: break
    case .starred: result = result.filter { $0.isStarred }
    }
    return result
  }

  /// Group words by day
  private var groupedWords: [(String, [CapturedWord])] {
    let calendar = Calendar.current
    let grouped = Dictionary(grouping: filteredWords) { word in
      calendar.startOfDay(for: word.capturedAt)
    }
    return grouped.sorted { $0.key > $1.key }.map { (date, words) in
      let label: String
      if calendar.isDateInToday(date) {
        label = "Today"
      } else if calendar.isDateInYesterday(date) {
        label = "Yesterday"
      } else {
        label = date.formatted(.dateTime.month(.wide).day())
      }
      return (label, words)
    }
  }

  private var isSelecting: Bool { editMode == .active }

  var body: some View {
    Group {
      if words.isEmpty {
        VStack(spacing: Spacing.lg) {
          Image(systemName: "textformat.abc")
            .font(.system(size: 48))
            .foregroundStyle(.leather.opacity(0.3))
          Text("No words yet")
            .font(.sectionTitle)
            .foregroundStyle(.leather)
          Text("Ask Luna about a word during a reading session and it will be saved here.")
            .font(.subheadline)
            .foregroundStyle(.leather.opacity(0.6))
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Spacing.xxl)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.lg) {
            // Filter chips
            HStack(spacing: Spacing.sm) {
              ForEach(WordFilter.allCases, id: \.self) { option in
                Button {
                  withAnimation(.easeInOut(duration: 0.2)) { filter = option }
                } label: {
                  HStack(spacing: Spacing.xs) {
                    if option == .starred {
                      Image(systemName: "star.fill")
                        .font(.caption2)
                    }
                    Text(option.rawValue)
                      .font(.subheadline)
                  }
                  .padding(.horizontal, Spacing.md)
                  .padding(.vertical, Spacing.sm)
                  .background(
                    filter == option ? Color.ink : .clear,
                    in: RoundedRectangle(cornerRadius: CornerRadius.chip)
                  )
                  .foregroundStyle(filter == option ? .parchment : .ink)
                  .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.chip)
                      .stroke(filter == option ? .clear : .ink.opacity(0.3), lineWidth: 1)
                  )
                }
                .buttonStyle(.plain)
              }
              Spacer()
            }
            .padding(.horizontal, Spacing.lg)

            // Grouped word list
            ForEach(groupedWords, id: \.0) { label, dayWords in
              VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(label)
                  .font(.caption)
                  .textCase(.uppercase)
                  .tracking(1)
                  .foregroundStyle(.leather)
                  .padding(.horizontal, Spacing.lg)

                ForEach(dayWords) { word in
                  if isSelecting {
                    Button {
                      toggleSelection(word)
                    } label: {
                      WordCardRow(word: word, isSelected: selection.contains(word.persistentModelID))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Spacing.lg)
                  } else {
                    SwipeableWordRow(
                      word: word,
                      onDelete: { deleteWord(word) },
                      onToggleStar: { toggleStar(word) }
                    ) {
                      NavigationLink(value: word) {
                        WordCardRow(word: word, isSelected: false)
                      }
                      .buttonStyle(.plain)
                    }
                  }
                }
              }
            }
          }
          .padding(.vertical, Spacing.lg)
          .padding(.bottom, isSelecting && !selection.isEmpty ? 80 : 0)
        }
        .searchable(text: $searchText, prompt: "Search words")
        .safeAreaInset(edge: .bottom) {
          if isSelecting && !selection.isEmpty {
            Button(role: .destructive) {
              showDeleteSelectedConfirm = true
            } label: {
              Label("Delete \(selection.count) Selected", systemImage: "trash")
                .frame(maxWidth: .infinity)
                .padding(Spacing.lg)
                .background(.brick, in: RoundedRectangle(cornerRadius: CornerRadius.button))
                .foregroundStyle(.parchment)
                .font(.headline)
            }
            .padding(Spacing.lg)
            .background(.parchment)
          }
        }
      }
    }
    .background(.parchment)
    .navigationDestination(for: CapturedWord.self) { word in
      WordDetailView(word: word)
    }
    .toolbar {
      if !words.isEmpty {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Button {
              withAnimation {
                if isSelecting {
                  editMode = .inactive
                  selection.removeAll()
                } else {
                  editMode = .active
                }
              }
            } label: {
              Label(isSelecting ? "Done" : "Select", systemImage: "checkmark.circle")
            }
            Button(role: .destructive) {
              showDeleteAllConfirm = true
            } label: {
              Label("Delete All", systemImage: "trash")
            }
          } label: {
            Image(systemName: "ellipsis.circle")
              .foregroundStyle(.ink)
          }
        }
      }
      #if DEBUG
      ToolbarItem(placement: .topBarLeading) {
        DebugInsertWordsButton()
      }
      #endif
    }
    .confirmationDialog(
      "Delete all \(words.count) words?",
      isPresented: $showDeleteAllConfirm,
      titleVisibility: .visible
    ) {
      Button("Delete All", role: .destructive) { deleteAll() }
      Button("Cancel", role: .cancel) { }
    } message: {
      Text("This will permanently remove all captured words from your library.")
    }
    .confirmationDialog(
      "Delete \(selection.count) selected word\(selection.count == 1 ? "" : "s")?",
      isPresented: $showDeleteSelectedConfirm,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) { deleteSelected() }
      Button("Cancel", role: .cancel) { }
    }
  }

  // MARK: - Selection

  private func toggleSelection(_ word: CapturedWord) {
    if selection.contains(word.persistentModelID) {
      selection.remove(word.persistentModelID)
    } else {
      selection.insert(word.persistentModelID)
    }
  }

  // MARK: - Star

  private func toggleStar(_ word: CapturedWord) {
    withAnimation {
      word.isStarred.toggle()
      try? modelContext.save()
    }
  }

  // MARK: - Deletion

  private func deleteWord(_ word: CapturedWord) {
    withAnimation {
      modelContext.delete(word)
      try? modelContext.save()
    }
  }

  private func deleteSelected() {
    withAnimation {
      for id in selection {
        if let word = words.first(where: { $0.persistentModelID == id }) {
          modelContext.delete(word)
        }
      }
      try? modelContext.save()
      selection.removeAll()
      editMode = .inactive
    }
  }

  private func deleteAll() {
    withAnimation {
      for word in words {
        modelContext.delete(word)
      }
      try? modelContext.save()
      selection.removeAll()
      editMode = .inactive
    }
  }
}

// MARK: - Debug: Insert Test Words

#if DEBUG
private struct DebugInsertWordsButton: View {
  @Environment(\.modelContext) private var modelContext
  @State private var isInserting = false

  /// Test words covering happy path, no-example, edge cases, and expected failures
  private static let testWords = [
    "ubiquitous", "benevolent", "pragmatic", "serendipity", "ephemeral",
    "luminous", "café", "naïve", "résumé", "well-read",
    "asdfghjkl",  // should fail — gibberish
  ]

  var body: some View {
    Button {
      guard !isInserting else { return }
      isInserting = true
      insertTestWords()
    } label: {
      if isInserting {
        ProgressView()
      } else {
        Label("Test Words", systemImage: "flask")
      }
    }
  }

  private func insertTestWords() {
    let ctx = modelContext
    var inserted: [CapturedWord] = []

    for word in Self.testWords {
      let captured = CapturedWord(text: word)
      ctx.insert(captured)
      inserted.append(captured)
    }
    try? ctx.save()

    // Look up definitions via on-device LLM
    for captured in inserted {
      let wordText = captured.text
      Task {
        do {
          let def = try await OnDeviceLLMService.shared.generateDefinition(
            word: wordText, bookTitle: nil
          )
          print("[TestWords LLM] ✅ '\(wordText)' → \(def.definition.prefix(60))…")
          captured.definition = def.definition
          captured.pronunciation = def.pronunciation.isEmpty ? nil : def.pronunciation
          captured.exampleSentence = def.exampleSentence.isEmpty ? nil : def.exampleSentence
          try? ctx.save()
        } catch {
          print("[TestWords LLM] ❌ '\(wordText)' → \(error.localizedDescription)")
        }
      }
    }

    // Reset state after a delay to let lookups finish
    Task {
      try? await Task.sleep(for: .seconds(5))
      isInserting = false
    }
  }
}
#endif

// MARK: - Word Card Row

private struct WordCardRow: View {
  let word: CapturedWord
  var isSelected: Bool = false

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.md) {
      // Amber left accent
      RoundedRectangle(cornerRadius: 2)
        .fill(.amber)
        .frame(width: 3)

      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text(word.text)
          .font(.serif(.headline, weight: .semibold))
          .foregroundStyle(.ink)
        if let definition = word.definition {
          Text(definition)
            .font(.subheadline)
            .foregroundStyle(.leather)
            .lineLimit(1)
        }
        if let book = word.book {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "book")
              .font(.caption2)
            Text("\(book.title)")
              .font(.caption)
          }
          .foregroundStyle(.leather.opacity(0.6))
        }
      }

      Spacer()

      if isSelected {
        Image(systemName: "checkmark.circle.fill")
          .font(.title3)
          .foregroundStyle(.ink)
      } else {
        Image(systemName: word.isStarred ? "star.fill" : "star")
          .font(.caption)
          .foregroundStyle(word.isStarred ? .amber : .leather.opacity(0.3))
      }
    }
    .padding(Spacing.lg)
    .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
    .warmShadow()
  }
}

// MARK: - Swipeable Word Row

private struct SwipeableWordRow<Content: View>: View {
  let word: CapturedWord
  let onDelete: () -> Void
  let onToggleStar: () -> Void
  @ViewBuilder let content: () -> Content

  @State private var offset: CGFloat = 0
  @GestureState private var dragOffset: CGFloat = 0

  private let buttonWidth: CGFloat = 72
  private var revealWidth: CGFloat { buttonWidth * 2 }

  private var currentOffset: CGFloat { offset + dragOffset }

  var body: some View {
    content()
      .background(alignment: .trailing) {
        // Action buttons anchored to the trailing edge of the card.
        // Width is driven by the current swipe offset, so they're invisible
        // (0-width) when at rest and grow as the user swipes left.
        HStack(spacing: 0) {
          Button {
            close()
            onToggleStar()
          } label: {
            VStack(spacing: 4) {
              Image(systemName: word.isStarred ? "star.slash.fill" : "star.fill")
                .font(.title3)
              Text(word.isStarred ? "Unstar" : "Star")
                .font(.caption2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.parchment)
            .background(.amber)
          }
          Button {
            close()
            onDelete()
          } label: {
            VStack(spacing: 4) {
              Image(systemName: "trash.fill")
                .font(.title3)
              Text("Delete")
                .font(.caption2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.parchment)
            .background(.brick)
          }
        }
        .frame(width: max(0, -currentOffset))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
      }
      .offset(x: currentOffset)
      .padding(.horizontal, Spacing.lg)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 15)
          .updating($dragOffset) { value, state, _ in
            let translation = value.translation.width
            // Ignore vertical-dominant gestures so ScrollView still works.
            guard abs(translation) > abs(value.translation.height) else { return }
            if offset == 0 {
              state = min(0, translation)
            } else {
              state = max(-revealWidth, min(0, offset + translation) - offset)
            }
          }
          .onEnded { value in
            let translation = value.translation.width
            guard abs(translation) > abs(value.translation.height) else { return }
            let velocity = value.predictedEndTranslation.width - translation
            withAnimation(.spring(duration: 0.3)) {
              if offset == 0 {
                if translation < -revealWidth / 2 || velocity < -50 {
                  offset = -revealWidth
                } else {
                  offset = 0
                }
              } else {
                if translation > revealWidth / 2 || velocity > 50 {
                  offset = 0
                } else {
                  offset = -revealWidth
                }
              }
            }
          }
      )
  }

  private func close() {
    withAnimation(.spring(duration: 0.3)) { offset = 0 }
  }
}
