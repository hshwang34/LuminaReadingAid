//
// WakeWordSpotting.swift
//
// The wake-phrase seam, plus the pure matcher behind it.
//
// The matcher is deliberately a plain value type with no audio, no recogniser and no
// I/O: wake-phrase quality is the single thing most likely to need tuning against
// real users (notably Korean-accented English), and tuning is only cheap if variants
// can be added and regression-tested without a device.
//
// v1 spots the phrase in the partial transcripts of Apple's on-device recogniser.
// The protocol exists so a dedicated low-power engine (Porcupine) or the iOS 26
// SpeechAnalyzer stack can replace that later without the session noticing.
//

import Foundation

/// Emitted when the wake phrase is heard.
struct WakeEvent: Sendable, Equatable {
  /// Anything the reader said *after* the wake phrase in the same breath.
  /// Often empty — people pause after "Hey Luna" — but when it's populated the
  /// session must not throw it away, or "Hey Luna what does precision mean" loses
  /// its question.
  let trailingTranscript: String
  let detectedAt: Date

  init(trailingTranscript: String, detectedAt: Date = Date()) {
    self.trailingTranscript = trailingTranscript
    self.detectedAt = detectedAt
  }
}

protocol WakeWordSpotting: AnyObject {
  /// Begin duty-cycled scanning. The stream yields one event per detection and
  /// finishes when `stopSpotting()` is called.
  func startSpotting() -> AsyncStream<WakeEvent>
  func stopSpotting()
}

// MARK: - Matcher

/// Recognises "Hey Luna" and its plausible mis-transcriptions.
struct WakePhraseMatcher: Sendable {

  struct Match: Equatable, Sendable {
    /// Text following the wake phrase, with original casing preserved.
    let trailing: String
    /// What was actually matched, for logging and tuning.
    let matchedPhrase: String
    /// Index (in the original string) just past the wake phrase.
    let endOffset: Int
  }

  /// Words a recogniser plausibly produces for the attention word before the name.
  /// "a" is included because "Hey" is frequently transcribed as "A" at low volume.
  private static let triggers: Set<String> = [
    "hey", "hay", "hi", "hello", "ok", "okay", "a", "eh",
  ]

  /// The assistant's name, matched with an edit-distance tolerance of 1 to absorb
  /// "lunar", "luma", "lena", "loona" and similar near-misses.
  private static let name = "luna"

  /// Some recognisers glue the phrase into one token.
  private static let mergedForms: Set<String> = ["heyluna", "heylunas", "hayluna"]

  /// Whether a trigger word is required, or a bare "Luna" is enough.
  /// Defaults to requiring one: the reader is holding a book, not talking to the
  /// phone, so false wakes are more costly than a missed one.
  var requiresTrigger: Bool = true

  init(requiresTrigger: Bool = true) {
    self.requiresTrigger = requiresTrigger
  }

  /// Scans a (possibly partial) transcript for the wake phrase.
  /// Returns the *last* match so that a long-running partial transcript containing
  /// several exchanges resolves to the most recent one.
  func match(in transcript: String) -> Match? {
    let tokens = Self.tokenize(transcript)
    guard !tokens.isEmpty else { return nil }

    var best: Match?

    for (index, token) in tokens.enumerated() {
      let normalized = token.normalized

      // Merged: "heyluna what does ..."
      if Self.mergedForms.contains(normalized)
        || (normalized.hasPrefix("hey") && Self.isName(String(normalized.dropFirst(3)))) {
        best = Self.makeMatch(tokens: tokens, phraseEnd: index, transcript: transcript,
                              phrase: token.text)
        continue
      }

      // Trigger + name: "hey luna what does ..."
      if Self.triggers.contains(normalized), index + 1 < tokens.count,
         Self.isName(tokens[index + 1].normalized) {
        best = Self.makeMatch(tokens: tokens, phraseEnd: index + 1, transcript: transcript,
                              phrase: "\(token.text) \(tokens[index + 1].text)")
        continue
      }

      // Bare name, only when explicitly allowed.
      if !requiresTrigger, Self.isName(normalized) {
        best = Self.makeMatch(tokens: tokens, phraseEnd: index, transcript: transcript,
                              phrase: token.text)
      }
    }

    return best
  }

  private static func makeMatch(
    tokens: [Token], phraseEnd: Int, transcript: String, phrase: String
  ) -> Match {
    let end = tokens[phraseEnd].end
    // Strip only the separator between the wake phrase and the question. Trailing
    // punctuation belongs to the question itself — "what does divine mean?" keeps
    // its question mark, which the recogniser's own punctuation model produced.
    let separators = CharacterSet(charactersIn: " ,.!?;:-—\n\t")
    var trailing = Substring(transcript.dropFirst(end))
    while let first = trailing.unicodeScalars.first, separators.contains(first) {
      trailing = trailing.dropFirst()
    }
    return Match(
      trailing: String(trailing).trimmingCharacters(in: .whitespacesAndNewlines),
      matchedPhrase: phrase,
      endOffset: end
    )
  }

  private static func isName(_ candidate: String) -> Bool {
    guard !candidate.isEmpty else { return false }
    if candidate == name { return true }
    // Only test plausible lengths — cheap guard before the distance computation.
    guard abs(candidate.count - name.count) <= 1 else { return false }
    return editDistance(Array(candidate), Array(name), atMost: 1)
  }

  // MARK: Tokenisation

  fileprivate struct Token {
    let text: String
    /// Offset just past this token in the original string.
    let end: Int
    let normalized: String
  }

  private static func tokenize(_ s: String) -> [Token] {
    var tokens: [Token] = []
    var current = ""

    for (offset, char) in s.enumerated() {
      if char.isLetter || char == "'" || char == "’" {
        current.append(char)
      } else if !current.isEmpty {
        tokens.append(Token(text: current, end: offset, normalized: normalize(current)))
        current = ""
      }
    }
    if !current.isEmpty {
      tokens.append(Token(text: current, end: s.count, normalized: normalize(current)))
    }
    return tokens
  }

  /// Lowercase, strip diacritics and apostrophes. Diacritic folding matters because
  /// recognisers sometimes emit "lună"-style forms.
  private static func normalize(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
      .replacingOccurrences(of: "'", with: "")
      .replacingOccurrences(of: "’", with: "")
  }

  /// Bounded Levenshtein: returns whether the distance is at most `k`.
  /// Exposed internally so the matcher's tolerance can be regression-tested.
  static func editDistance(_ a: [Character], _ b: [Character], atMost k: Int) -> Bool {
    if abs(a.count - b.count) > k { return false }
    if a.isEmpty { return b.count <= k }
    if b.isEmpty { return a.count <= k }

    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)

    for i in 1...a.count {
      current[0] = i
      var rowMin = current[0]
      for j in 1...b.count {
        let cost = a[i - 1] == b[j - 1] ? 0 : 1
        current[j] = Swift.min(
          previous[j] + 1,       // deletion
          current[j - 1] + 1,    // insertion
          previous[j - 1] + cost // substitution
        )
        rowMin = Swift.min(rowMin, current[j])
      }
      // Every remaining path is already worse than the budget.
      if rowMin > k { return false }
      swap(&previous, &current)
    }
    return previous[b.count] <= k
  }
}
