import SwiftUI
import SwiftData

struct BookDetailView: View {
  @Bindable var book: Book
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @State private var showDeleteConfirm = false
  @State private var showBookQuiz = false
  @StateObject private var quizVM = PracticeViewModel()

  // MARK: - Derived stats

  private var lastReadDate: Date? {
    let ended = book.sessions.compactMap(\.endedAt).max()
    if let ended { return ended }
    return book.sessions.map(\.startedAt).max()
  }

  private var pagesPerHour: Int? {
    var totalPages = 0
    var totalSeconds: TimeInterval = 0
    for session in book.sessions {
      guard let start = session.startPage,
            let end = session.endPage,
            let endedAt = session.endedAt,
            end > start else { continue }
      let duration = endedAt.timeIntervalSince(session.startedAt)
      guard duration > 0 else { continue }
      totalPages += (end - start)
      totalSeconds += duration
    }
    guard totalSeconds > 0, totalPages > 0 else { return nil }
    let hours = totalSeconds / 3600.0
    return Int((Double(totalPages) / hours).rounded())
  }

  private var sortedWords: [CapturedWord] {
    book.words.sorted { $0.capturedAt > $1.capturedAt }
  }

  private var quizEligibleWords: [CapturedWord] {
    book.words.filter { $0.definition != nil }
  }

  private var sortedPassages: [CapturedPassage] {
    book.passages.sorted { $0.capturedAt > $1.capturedAt }
  }

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.xl) {
        coverHeader
        statsHeader
        ctaButtons
        wordsSection
        quotesSection
        finishedToggle
      }
      .padding(.vertical, Spacing.lg)
    }
    .background(.parchment)
    .navigationTitle(book.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button(role: .destructive) {
            showDeleteConfirm = true
          } label: {
            Label("Delete Book", systemImage: "trash")
          }
        } label: {
          Image(systemName: "ellipsis.circle")
            .foregroundStyle(.ink)
        }
      }
    }
    .fullScreenCover(isPresented: $showBookQuiz) {
      NavigationStack {
        QuizView(viewModel: quizVM, quizType: .byBook)
      }
    }
    .confirmationDialog(
      "Delete \"\(book.title)\"?",
      isPresented: $showDeleteConfirm,
      titleVisibility: .visible
    ) {
      Button("Delete Book", role: .destructive) { deleteBook() }
      Button("Cancel", role: .cancel) { }
    } message: {
      Text("This removes the book, its \(book.words.count) word\(book.words.count == 1 ? "" : "s"), \(book.passages.count) quote\(book.passages.count == 1 ? "" : "s"), and all reading sessions. The next time this book is detected, identification runs from scratch.")
    }
  }

  // MARK: - Sections

  private var coverHeader: some View {
    VStack(spacing: Spacing.md) {
      BookCoverView(imageData: book.coverImageData, size: .detail)

      Text(book.title)
        .font(.sectionTitle)
        .foregroundStyle(.ink)
        .multilineTextAlignment(.center)

      if !book.author.isEmpty {
        Text("by \(book.author)")
          .font(.subheadline)
          .foregroundStyle(.leather)
      }

      if book.isFinished {
        Text("FINISHED")
          .font(.caption2)
          .tracking(1.2)
          .foregroundStyle(.parchment)
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.xs)
          .background(.amber, in: Capsule())
      }
    }
    .padding(.horizontal, Spacing.lg)
  }

  private var statsHeader: some View {
    let columns = [
      GridItem(.flexible(), spacing: Spacing.sm),
      GridItem(.flexible(), spacing: Spacing.sm)
    ]
    return LazyVGrid(columns: columns, spacing: Spacing.sm) {
      StatTile(label: "Last Read", value: lastReadValue)
      StatTile(label: "Pages/Hr", value: pagesPerHour.map(String.init) ?? "—")
      StatTile(label: "Words", value: "\(book.words.count)")
      StatTile(label: "Quotes", value: "\(book.passages.count)")
    }
    .padding(.horizontal, Spacing.lg)
  }

  private var lastReadValue: String {
    guard let date = lastReadDate else { return "—" }
    let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
    if days <= 0 { return "Today" }
    if days == 1 { return "Yesterday" }
    if days < 14 { return "\(days) days ago" }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }

  private var ctaButtons: some View {
    // One action. Reading this book means: go to the Session tab with this book
    // already bound — every word captured lands in this bucket, no linking after.
    Button {
      SessionLaunchRouter.shared.requestSession(book: book)
    } label: {
      Label("Read This Book", systemImage: "waveform.and.mic")
        .frame(maxWidth: .infinity)
        .padding(Spacing.lg)
        .background(.amber, in: RoundedRectangle(cornerRadius: CornerRadius.button))
        .foregroundStyle(.white)
        .font(.headline)
    }
    .padding(.horizontal, Spacing.lg)
  }

  @ViewBuilder
  private var wordsSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(alignment: .firstTextBaseline) {
        Text("Words (\(book.words.count))")
          .font(.sectionTitle)
          .foregroundStyle(.ink)
        Spacer()
        // The loop the library exists for: this book's words, straight into a quiz.
        if quizEligibleWords.count >= 2 {
          Button {
            showBookQuiz = true
            Task { await quizVM.startQuiz(words: quizEligibleWords, type: .byBook) }
          } label: {
            HStack(spacing: Spacing.xs) {
              Text("Practice")
              Image(systemName: "chevron.right").font(.caption2)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.amber)
          }
        }
      }
      .padding(.horizontal, Spacing.lg)

      if book.words.isEmpty {
        EmptySectionCard(
          icon: "textformat.abc",
          message: "No words yet. Ask Luna about a word while reading this book."
        )
        .padding(.horizontal, Spacing.lg)
      } else {
        VStack(spacing: Spacing.sm) {
          ForEach(sortedWords) { word in
            NavigationLink(value: word) {
              BookWordRow(word: word)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, Spacing.lg)
      }
    }
    .navigationDestination(for: CapturedWord.self) { word in
      WordDetailView(word: word)
    }
  }

  @ViewBuilder
  private var quotesSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Quotes (\(book.passages.count))")
        .font(.sectionTitle)
        .foregroundStyle(.ink)
        .padding(.horizontal, Spacing.lg)

      if book.passages.isEmpty {
        EmptySectionCard(
          icon: "quote.opening",
          message: "No quotes captured yet. Pinch and drag across a passage while reading to capture it."
        )
        .padding(.horizontal, Spacing.lg)
      } else {
        VStack(spacing: Spacing.md) {
          ForEach(sortedPassages) { passage in
            PassageCard(passage: passage)
          }
        }
        .padding(.horizontal, Spacing.lg)
      }
    }
  }

  private var finishedToggle: some View {
    Button {
      book.isFinished.toggle()
      try? modelContext.save()
    } label: {
      Text(book.isFinished ? "Mark as Reading" : "Mark as Finished")
        .font(.headline)
        .foregroundStyle(.ink)
        .frame(maxWidth: .infinity)
        .padding(Spacing.lg)
        .overlay(
          RoundedRectangle(cornerRadius: CornerRadius.button)
            .stroke(.ink, lineWidth: 1.5)
        )
    }
    .buttonStyle(.plain)
    .padding(.horizontal, Spacing.lg)
  }

  // MARK: - Actions

  private func deleteBook() {
    let ctx = modelContext
    let target = book
    dismiss()
    DispatchQueue.main.async {
      ctx.delete(target)
      try? ctx.save()
    }
  }
}

// MARK: - Stat Tile

private struct StatTile: View {
  let label: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(value)
        .font(.title2.bold())
        .foregroundStyle(.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      Text(label)
        .font(.caption)
        .textCase(.uppercase)
        .tracking(0.8)
        .foregroundStyle(.leather)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.md)
    .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
    .warmShadow(.subtle)
  }
}

// MARK: - Book Word Row
//
// Book-detail variant of the word row. Includes page number and context phrase,
// which the Words-tab row omits. Visually mirrors `WordCardRow` in WordsTabView
// (amber accent bar, white card, warm shadow) without sharing code, so the tab
// list stays dense and this view can breathe.

private struct BookWordRow: View {
  let word: CapturedWord

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.md) {
      RoundedRectangle(cornerRadius: 2)
        .fill(.amber)
        .frame(width: 3)

      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
          Text(word.text)
            .font(.serif(.headline, weight: .semibold))
            .foregroundStyle(.ink)
          // Mastery at a glance: the dot deepens from pale to full amber (L0-L5).
          Circle()
            .fill(.amber.opacity(word.masteryLevel == 0 ? 0.15 : 0.2 + 0.16 * Double(word.masteryLevel)))
            .frame(width: 8, height: 8)
            .accessibilityLabel("Mastery level \(word.masteryLevel) of 5")
          Spacer()
          if let page = word.pageNumber {
            Text("p.\(page)")
              .font(.caption)
              .foregroundStyle(.leather.opacity(0.6))
          }
        }
        if let definition = word.definition {
          Text(definition)
            .font(.subheadline)
            .foregroundStyle(.leather)
            .lineLimit(1)
        }
        if let context = word.contextPhrase, !context.isEmpty {
          Text("\u{201C}\(context)\u{201D}")
            .font(.caption)
            .italic()
            .foregroundStyle(.leather.opacity(0.6))
            .lineLimit(1)
        }
      }

      if word.isStarred {
        Image(systemName: "star.fill")
          .font(.caption)
          .foregroundStyle(.amber)
      }
    }
    .padding(Spacing.lg)
    .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
    .warmShadow()
  }
}

// MARK: - Passage Card

private struct PassageCard: View {
  let passage: CapturedPassage

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(alignment: .center, spacing: Spacing.sm) {
        RoundedRectangle(cornerRadius: 2)
          .fill(.amber)
          .frame(width: 3, height: 14)
        if let page = passage.pageNumber {
          Text("p.\(page)")
            .font(.caption)
            .foregroundStyle(.leather.opacity(0.6))
        }
        Spacer()
        Text(passage.capturedAt, format: .dateTime.month(.abbreviated).day())
          .font(.caption)
          .foregroundStyle(.leather.opacity(0.4))
      }

      Text(passage.text)
        .font(.serif(.body))
        .foregroundStyle(.ink)
        .lineSpacing(4)
        .fixedSize(horizontal: false, vertical: true)

      if let data = passage.imageData, let uiImage = UIImage(data: data) {
        Image(uiImage: uiImage)
          .resizable()
          .scaledToFit()
          .frame(maxHeight: 120)
          .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
      }
    }
    .padding(Spacing.lg)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
    .warmShadow(.subtle)
  }
}

// MARK: - Empty Section Card

private struct EmptySectionCard: View {
  let icon: String
  let message: String

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.md) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundStyle(.leather.opacity(0.4))
      Text(message)
        .font(.caption)
        .foregroundStyle(.leather.opacity(0.6))
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
    }
    .padding(Spacing.lg)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
  }
}
