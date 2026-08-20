//
// CoverMatching.swift
//
// Pure functions for normalizing OCR text, fuzzy-matching it against the
// local library, and scoring Open Library candidates.
//

import Foundation

enum CoverMatching {

  // MARK: - Normalization

  private static let leadingArticles: Set<String> = ["the", "a", "an"]

  /// NFKC fold → lowercase → strip punctuation (keeps apostrophes) →
  /// drop leading article → collapse whitespace. Applied to both sides of
  /// every comparison so inputs don't need to be pre-normalized.
  static func normalize(_ text: String) -> String {
    let folded = text.precomposedStringWithCompatibilityMapping.lowercased()

    var stripped = ""
    stripped.reserveCapacity(folded.count)
    for ch in folded {
      if ch.isLetter || ch.isNumber || ch == "'" {
        stripped.append(ch)
      } else {
        stripped.append(" ")
      }
    }

    var tokens = stripped.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    if let first = tokens.first, leadingArticles.contains(first) {
      tokens.removeFirst()
    }
    return tokens.joined(separator: " ")
  }

  // MARK: - Fuzzy score (token-set ratio)

  /// Order-independent token-set ratio in [0, 1].
  /// score = 2 * |A ∩ B| / (|A| + |B|)
  static func fuzzyScore(_ a: String, _ b: String) -> Double {
    let aTokens = Set(normalize(a).split(whereSeparator: { $0.isWhitespace }).map(String.init))
    let bTokens = Set(normalize(b).split(whereSeparator: { $0.isWhitespace }).map(String.init))
    guard !aTokens.isEmpty, !bTokens.isEmpty else { return 0 }
    let intersection = aTokens.intersection(bTokens).count
    let denominator = aTokens.count + bTokens.count
    return 2.0 * Double(intersection) / Double(denominator)
  }

  // MARK: - Local library match

  /// Linear scan over the library. Returns the best matching book and its
  /// combined score, or nil if best < 0.5 (the floor below which we never
  /// claim a local match).
  static func localMatch(ocrTitle: String,
                         ocrAuthor: String,
                         books: [Book]) -> (book: Book, score: Double)? {
    guard !books.isEmpty else { return nil }
    guard !ocrTitle.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

    let hasAuthor = !ocrAuthor.trimmingCharacters(in: .whitespaces).isEmpty
    var best: (book: Book, score: Double)? = nil

    for book in books {
      let titleScore = max(
        fuzzyScore(ocrTitle, book.title),
        fuzzyScore(ocrTitle, book.coverTitleOCR ?? "")
      )
      let combined: Double
      if hasAuthor {
        let authorScore = max(
          fuzzyScore(ocrAuthor, book.author),
          fuzzyScore(ocrAuthor, book.coverAuthorOCR ?? "")
        )
        combined = 0.7 * titleScore + 0.3 * authorScore
      } else {
        combined = titleScore
      }

      if best == nil || combined > best!.score {
        best = (book, combined)
      }
    }

    guard let best, best.score >= 0.5 else { return nil }
    return best
  }

  // MARK: - Open Library candidate selection

  /// Scores Open Library candidates against the OCR guesses and decides:
  /// - `auto` is non-nil when the top candidate is confident enough to pick silently
  /// - otherwise `picker` contains up to 3 candidates to present to the user
  static func selectTopCandidate(_ candidates: [BookMetadataCandidate],
                                 ocrTitle: String,
                                 ocrAuthor: String)
                                 -> (auto: BookMetadataCandidate?, picker: [BookMetadataCandidate]) {
    guard !candidates.isEmpty else { return (nil, []) }
    let hasAuthor = !ocrAuthor.trimmingCharacters(in: .whitespaces).isEmpty

    var scored: [BookMetadataCandidate] = candidates.map { candidate in
      let titleFuzzy = fuzzyScore(ocrTitle, candidate.title)
      let baseFuzzy: Double
      if hasAuthor {
        let authorFuzzy = fuzzyScore(ocrAuthor, candidate.author)
        baseFuzzy = 0.7 * titleFuzzy + 0.3 * authorFuzzy
      } else {
        baseFuzzy = titleFuzzy
      }
      let editionBonus = min(Double(candidate.editionCount), 20.0) / 20.0 * 0.05
      var updated = candidate
      updated.fuzzyScore = baseFuzzy + editionBonus
      return updated
    }

    scored.sort { $0.fuzzyScore > $1.fuzzyScore }
    let top = scored[0]
    let second = scored.count > 1 ? scored[1].fuzzyScore : 0

    if top.fuzzyScore >= 0.85 && (top.fuzzyScore - second) >= 0.12 {
      return (top, [])
    }
    return (nil, Array(scored.prefix(3)))
  }
}
