//
// SessionBookLinker.swift
//
// Binds a reading session to a book, retroactively. One mechanism, two callers:
// the mid-session book picker on the Session tab (the reader names the book while
// Luna is still listening) and the orphan-link sheet after an unbound session
// ends. Both need the same three things to happen — the session row points at the
// book, the failed cover attempt seeds the book's identification data, and every
// capture from the session's time window that is still bookless gets stamped.
//

import Foundation
import SwiftData

@MainActor
enum SessionBookLinker {

  /// Bind `session` to `book` and stamp the session's orphaned captures.
  static func link(session: ReadingSession, to book: Book, in modelContext: ModelContext) {
    session.book = book

    // Seed the book's pHash index from the session's failed attempt, but only if
    // the book doesn't already have one (don't clobber data from a previous
    // successful identification).
    if book.coverPHashHex == nil, let hash = session.coverAttemptPHashHex {
      book.coverPHashHex = hash
    }
    if book.coverCanonicalImageData == nil, let data = session.coverAttemptImageData {
      book.coverCanonicalImageData = data
    }

    // Retroactive stamping of captures in this session's time window. An open
    // session has no end yet — its window runs to now.
    let start = session.startedAt
    let end = session.endedAt ?? Date()
    let wordFetch = FetchDescriptor<CapturedWord>(
      predicate: #Predicate<CapturedWord> {
        $0.book == nil && $0.capturedAt >= start && $0.capturedAt <= end
      }
    )
    if let orphanWords = try? modelContext.fetch(wordFetch) {
      for word in orphanWords { word.book = book }
      Log.session.info("stamped \(orphanWords.count) words onto \"\(book.title, privacy: .public)\"")
    }
    let passageFetch = FetchDescriptor<CapturedPassage>(
      predicate: #Predicate<CapturedPassage> {
        $0.book == nil && $0.capturedAt >= start && $0.capturedAt <= end
      }
    )
    if let orphanPassages = try? modelContext.fetch(passageFetch) {
      for passage in orphanPassages { passage.book = book }
    }

    try? modelContext.save()
  }
}
