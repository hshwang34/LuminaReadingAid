//
// OrphanSessionLinkView.swift
//
// Presented at the end of a streaming session when cover identification
// failed and the user never pre-bound a book. Shows the canonical cover image
// we tried to match (for visual confirmation) and three ways to resolve the
// orphan state:
//
//   1. Pick an existing book from the local library.
//   2. Search Open Library and register one of the matches as a new book.
//   3. Skip — leave the session unbound.
//
// Whichever book the user picks becomes the session's bound book. All
// captures made during that session that are currently orphaned (book == nil,
// within the session's time window) are retroactively stamped with the book.
// If the session has a pHash from its failed cover attempt, it's migrated onto
// the book so future sessions can recover via the identification service's
// pHash tier without any manual intervention.
//

import SwiftData
import SwiftUI

struct OrphanSessionLinkView: View {
  let session: ReadingSession
  let onComplete: () -> Void

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @Query(sort: \Book.dateAdded, order: .reverse) private var libraryBooks: [Book]

  @State private var searchText: String = ""
  @State private var searchResults: [BookMetadataCandidate] = []
  @State private var searchTask: Task<Void, Never>?
  @State private var isSearching: Bool = false
  @State private var searchError: String?
  @State private var coverThumbs: [URL: Data] = [:]

  /// Actor — must be awaited from async context.
  private let metadataService = BookMetadataService()

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          header

          TextField("Search for a book…", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, Spacing.lg)
            .onChange(of: searchText) { _, newValue in scheduleSearch(newValue) }
            .submitLabel(.search)

          if isSearching {
            HStack {
              Spacer()
              ProgressView().padding(.vertical, Spacing.sm)
              Spacer()
            }
          }
          if let searchError {
            Text(searchError)
              .font(.caption)
              .foregroundStyle(.orange)
              .padding(.horizontal, Spacing.lg)
          }

          if !searchResults.isEmpty {
            sectionHeader("Open Library results")
            VStack(spacing: Spacing.sm) {
              ForEach(Array(searchResults.enumerated()), id: \.offset) { _, candidate in
                Button {
                  Task { await link(toCandidate: candidate) }
                } label: {
                  candidateRow(candidate)
                }
                .buttonStyle(.plain)
              }
            }
            .padding(.horizontal, Spacing.lg)
          }

          if !libraryBooks.isEmpty {
            sectionHeader("Your library")
            VStack(spacing: Spacing.sm) {
              ForEach(libraryBooks) { book in
                Button {
                  link(toExisting: book)
                } label: {
                  libraryRow(book)
                }
                .buttonStyle(.plain)
              }
            }
            .padding(.horizontal, Spacing.lg)
          }

          if libraryBooks.isEmpty && searchResults.isEmpty && !isSearching {
            Text("Type above to search Open Library, or add a book to your library first.")
              .font(.caption)
              .foregroundStyle(.leather.opacity(0.7))
              .padding(.horizontal, Spacing.lg)
              .padding(.top, Spacing.md)
          }
        }
        .padding(.vertical, Spacing.lg)
      }
      .background(.parchment)
      .navigationTitle("Link Your Session")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Skip") { skip() }
        }
      }
      .onAppear {
        if let ocrTitle = session.coverAttemptOCRTitle,
           !ocrTitle.trimmingCharacters(in: .whitespaces).isEmpty,
           searchText.isEmpty {
          searchText = ocrTitle
        }
      }
    }
    .interactiveDismissDisabled()
  }

  // MARK: - Header

  @ViewBuilder
  private var header: some View {
    HStack(alignment: .top, spacing: Spacing.lg) {
      if let data = session.coverAttemptImageData, let ui = UIImage(data: data) {
        Image(uiImage: ui)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 90, height: 135)
          .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
          .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card)
              .strokeBorder(.leather.opacity(0.3), lineWidth: 1)
          )
          .warmShadow()
      } else {
        RoundedRectangle(cornerRadius: CornerRadius.card)
          .fill(.leather.opacity(0.15))
          .frame(width: 90, height: 135)
          .overlay(
            Image(systemName: "book.closed")
              .font(.system(size: 28))
              .foregroundStyle(.leather.opacity(0.5))
          )
      }
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("We couldn't identify this book")
          .font(.sectionTitle)
          .foregroundStyle(.ink)
        Text("Pick the book you were reading below, or search Open Library for it.")
          .font(.subheadline)
          .foregroundStyle(.leather)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.lg)
  }

  // MARK: - Rows

  private func libraryRow(_ book: Book) -> some View {
    HStack(spacing: Spacing.md) {
      coverThumb(data: book.coverImageData ?? book.coverCanonicalImageData, url: nil)
      VStack(alignment: .leading, spacing: 2) {
        Text(book.title)
          .font(.headline)
          .foregroundStyle(.ink)
          .lineLimit(2)
        if !book.author.isEmpty {
          Text(book.author)
            .font(.caption)
            .foregroundStyle(.leather)
            .lineLimit(1)
        }
      }
      Spacer()
      Image(systemName: "chevron.right")
        .font(.caption)
        .foregroundStyle(.leather.opacity(0.6))
    }
    .padding(Spacing.md)
    .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
  }

  private func candidateRow(_ candidate: BookMetadataCandidate) -> some View {
    HStack(spacing: Spacing.md) {
      coverThumb(data: nil, url: candidate.coverImageURL)
      VStack(alignment: .leading, spacing: 2) {
        Text(candidate.title)
          .font(.headline)
          .foregroundStyle(.ink)
          .lineLimit(2)
        if !candidate.author.isEmpty {
          Text(candidate.author)
            .font(.caption)
            .foregroundStyle(.leather)
            .lineLimit(1)
        }
      }
      Spacer()
      Image(systemName: "plus.circle")
        .font(.system(size: 18))
        .foregroundStyle(.amber)
    }
    .padding(Spacing.md)
    .background(.linen.opacity(0.6), in: RoundedRectangle(cornerRadius: CornerRadius.card))
  }

  @ViewBuilder
  private func coverThumb(data: Data?, url: URL?) -> some View {
    if let data, let ui = UIImage(data: data) {
      Image(uiImage: ui)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: 44, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    } else if let url, let cached = coverThumbs[url], let ui = UIImage(data: cached) {
      Image(uiImage: ui)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: 44, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    } else {
      RoundedRectangle(cornerRadius: 4)
        .fill(.leather.opacity(0.15))
        .frame(width: 44, height: 60)
        .overlay(
          Image(systemName: "book")
            .font(.caption)
            .foregroundStyle(.leather.opacity(0.5))
        )
        .task(id: url) {
          guard let url else { return }
          if coverThumbs[url] != nil { return }
          if let data = try? await metadataService.fetchCoverImage(url) {
            await MainActor.run { coverThumbs[url] = data }
          }
        }
    }
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.sectionTitle)
      .foregroundStyle(.ink)
      .padding(.horizontal, Spacing.lg)
  }

  // MARK: - Search

  /// Debounced Open Library search. Cancels any in-flight task and schedules a
  /// new one 400 ms after the user stops typing.
  private func scheduleSearch(_ text: String) {
    searchTask?.cancel()
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 3 else {
      searchResults = []
      isSearching = false
      return
    }
    searchTask = Task {
      try? await Task.sleep(for: .milliseconds(400))
      if Task.isCancelled { return }
      await runSearch(query: trimmed)
    }
  }

  private func runSearch(query: String) async {
    isSearching = true
    searchError = nil
    do {
      let results = try await metadataService.search(title: query, author: "")
      if Task.isCancelled { return }
      searchResults = results
    } catch {
      if Task.isCancelled { return }
      searchResults = []
      searchError = "Search failed — check your connection."
    }
    isSearching = false
  }

  // MARK: - Linking

  /// Tap an existing library book → bind + retroactive stamp + migrate pHash.
  private func link(toExisting book: Book) {
    performLink(to: book)
    onComplete()
    dismiss()
  }

  /// Tap an Open Library candidate → create or merge a Book, then link.
  private func link(toCandidate candidate: BookMetadataCandidate) async {
    let canonicalData = session.coverAttemptImageData
    let book = BookFactory.createOrUpdate(
      from: candidate,
      in: modelContext,
      canonicalCoverData: canonicalData,
      ocrTitle: session.coverAttemptOCRTitle ?? "",
      ocrAuthor: session.coverAttemptOCRAuthor ?? "",
      source: "openlibrary-manual"
    )
    // Fire-and-forget cover fetch. If the book already has a public cover
    // from a previous identification, skip.
    if book.coverImageData == nil, let url = candidate.coverImageURL {
      Task.detached {
        if let data = try? await BookMetadataService().fetchCoverImage(url) {
          await MainActor.run {
            if book.coverImageData == nil {
              book.coverImageData = data
              try? modelContext.save()
            }
          }
        }
      }
    }
    performLink(to: book)
    onComplete()
    dismiss()
  }

  private func skip() {
    onComplete()
    dismiss()
  }

  /// Shared finalizer for both tap paths: bind the session, migrate the
  /// failed-attempt pHash + canonical image onto the book, and retroactively
  /// stamp orphan captures from this session's time window.
  private func performLink(to book: Book) {
    session.book = book

    // Seed the book's pHash index from the session's failed attempt, but
    // only if the book doesn't already have one (don't clobber data from a
    // previous successful identification).
    if book.coverPHashHex == nil, let hash = session.coverAttemptPHashHex {
      book.coverPHashHex = hash
    }
    if book.coverCanonicalImageData == nil, let data = session.coverAttemptImageData {
      book.coverCanonicalImageData = data
    }

    // Retroactive stamping of captures in this session's time window.
    // SwiftData #Predicate supports nil comparisons for optional relationships
    // and range comparisons on Date.
    let start = session.startedAt
    let end = session.endedAt ?? Date()
    let wordFetch = FetchDescriptor<CapturedWord>(
      predicate: #Predicate<CapturedWord> {
        $0.book == nil && $0.capturedAt >= start && $0.capturedAt <= end
      }
    )
    if let orphanWords = try? modelContext.fetch(wordFetch) {
      for word in orphanWords { word.book = book }
      #if DEBUG
      NSLog("[Orphan] stamped \(orphanWords.count) words onto \"\(book.title)\"")
      #endif
    }
    let passageFetch = FetchDescriptor<CapturedPassage>(
      predicate: #Predicate<CapturedPassage> {
        $0.book == nil && $0.capturedAt >= start && $0.capturedAt <= end
      }
    )
    if let orphanPassages = try? modelContext.fetch(passageFetch) {
      for passage in orphanPassages { passage.book = book }
      #if DEBUG
      NSLog("[Orphan] stamped \(orphanPassages.count) passages onto \"\(book.title)\"")
      #endif
    }

    try? modelContext.save()
  }
}
