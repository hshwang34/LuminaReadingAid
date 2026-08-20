//
// WordNormalizer.swift
//
// Strips OCR artifacts from a captured word so it's suitable for dictionary lookup
// and storage in the user's vocabulary list. Handles leading/trailing punctuation,
// quotes, brackets, dashes, ellipses, smart quotes, case, and stray whitespace.
//
// Internal apostrophes and hyphens are preserved so contractions ("don't") and
// compound words ("mother-in-law") survive intact.
//

import Foundation

enum WordNormalizer {

  /// Characters stripped from the leading and trailing edges of a raw OCR word.
  /// Covers ASCII and Unicode punctuation/symbols:
  ///   - periods, commas, semicolons, colons, question/exclamation marks
  ///   - single and double quotes (straight and curly: ' ' " " ‘ ’ “ ”)
  ///   - parentheses, brackets, braces
  ///   - hyphens, en dashes, em dashes, minus signs, underscores
  ///   - ellipsis (both "…" and "...")
  ///   - math symbols, currency, bullets, asterisks
  ///   - whitespace and newlines
  private static let edgeStripSet: CharacterSet = {
    CharacterSet.punctuationCharacters
      .union(.symbols)
      .union(.whitespacesAndNewlines)
  }()

  /// Cleans a raw OCR word for storage and dictionary lookup.
  ///
  /// Pipeline:
  ///   1. Unicode NFC normalize (collapses composed forms, standardizes quotes)
  ///   2. Trim whitespace
  ///   3. If there's internal whitespace, take only the first whitespace-delimited chunk
  ///      (OCR occasionally joins adjacent words; only the closest word is the target)
  ///   4. Strip leading and trailing punctuation, symbols, dashes, quotes
  ///   5. Lowercase for consistent storage and case-insensitive dictionary lookup
  ///   6. Reject if empty or contains no letters (e.g. "123", "---", "...")
  ///
  /// Returns nil if the input is not a usable word.
  static func normalize(_ raw: String) -> String? {
    // 1. Unicode NFC
    var s = raw.precomposedStringWithCanonicalMapping

    // 2. Trim outer whitespace
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }

    // 3. If OCR produced multiple whitespace-separated tokens, keep only the first.
    //    The word selector in WordCaptureService picks one word near the fingertip,
    //    but if OCR lumps adjacent words together we still want a single clean token.
    if let space = s.firstIndex(where: { $0.isWhitespace }) {
      s = String(s[..<space])
      guard !s.isEmpty else { return nil }
    }

    // 4. Strip leading/trailing punctuation, symbols, quotes, dashes.
    //    Uses unicode scalars so multi-byte punctuation (curly quotes, em dashes,
    //    ellipsis character) is handled correctly.
    while let first = s.unicodeScalars.first, edgeStripSet.contains(first) {
      s.removeFirst()
    }
    while let last = s.unicodeScalars.last, edgeStripSet.contains(last) {
      s.removeLast()
    }
    guard !s.isEmpty else { return nil }

    // 5. Lowercase. Dictionary lookup is case-insensitive and the word list displays
    //    consistently. Proper nouns lose their capital but the word itself is preserved.
    s = s.lowercased()

    // 6. Require at least one letter — rejects "123", pure punctuation residue, etc.
    guard s.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else {
      return nil
    }

    return s
  }
}
