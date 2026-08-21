//
// IntentRouter.swift
//
// What remains of the router after the answer path went LM-native: word spotting for
// the dictionary prefetch, and the small text utilities around it.
//
// There is deliberately no routing here any more. The model receives the reader's
// words verbatim and answers them; nothing classifies an utterance on the way in.
// (The history of why: a regex table dropped real questions it had no pattern for,
// and a classification generation doubled latency for nothing a good answer didn't
// already contain.)
//

import Foundation

enum IntentRouter {

  // MARK: - Prefetch word spotting

  /// The word a (possibly partial) utterance is probably asking about, or nil.
  ///
  /// Used for two free things: warming the dictionary cache while the reader is
  /// still talking, and attaching the cached senses to the prompt as a single
  /// grounding line. Wrong guesses cost a cache entry nobody reads; missed guesses
  /// cost an ungrounded answer. Neither costs latency.
  static func likelyTargetWord(in partial: String) -> String? {
    let text = clean(partial)
    guard !text.isEmpty else { return nil }

    for rule in prefetchRules {
      guard let match = text.firstMatch(of: rule),
            match.count > 1,
            let captured = match[1].substring else { continue }
      guard let word = extractWord(from: String(captured)), !isAnaphoric(word) else { continue }
      return word
    }
    return nil
  }

  /// Lead-in shapes that only ever precede a word lookup. Each captures the first
  /// plausible word after the phrase, so they fire on incomplete sentences —
  /// which is the whole value: the head start exists only mid-sentence.
  private static let prefetchRules: [Regex<AnyRegexOutput>] = {
    func rx(_ pattern: String) -> Regex<AnyRegexOutput> {
      // Compile-time literals covered by IntentRouterTests; a failure here is an
      // authoring bug, not a runtime condition.
      try! Regex(pattern).ignoresCase()
    }
    return [
      rx(#"\bwhat does (?:the word )?([\p{L}][\p{L}'’\-]+)"#),
      rx(#"\b(?:meaning|definition) of (?:the word )?([\p{L}][\p{L}'’\-]+)"#),
      rx(#"\bdefine (?:the word )?([\p{L}][\p{L}'’\-]+)"#),
      rx(#"\bexplain (?:what )?(?:the word )?([\p{L}][\p{L}'’\-]+)"#),
      rx(#"\bwhat (?:the word )?([\p{L}][\p{L}'’\-]+) means"#),
      rx(#"\bpronounce (?:the word )?([\p{L}][\p{L}'’\-]+)"#),
      rx(#"\bhow(?:'s| is) ([\p{L}][\p{L}'’\-]+) pronounced"#),
      rx(#"\buse (?:the word )?([\p{L}][\p{L}'’\-]+)"#),
      rx(#"\bwhat(?:'s| is) (?:an?|the word) ([\p{L}][\p{L}'’\-]+)"#),
    ]
  }()

  // MARK: - Text utilities

  /// Collapses whitespace without destroying casing.
  static func clean(_ utterance: String) -> String {
    utterance
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
  }

  /// Words that surround the word being asked about without being it.
  private static let filler: Set<String> = [
    "the", "a", "an", "word", "term", "this", "that", "mean", "means",
    "meaning", "please", "again", "exactly", "actually", "really",
  ]

  /// Pulls the target word out of a captured phrase, stripping filler.
  /// "the word precision" → "precision"; "precision," → "precision".
  static func extractWord(from raw: String) -> String? {
    var tokens = raw
      .split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" && $0 != "-" })
      .map { $0.lowercased() }

    while let first = tokens.first, filler.contains(first) { tokens.removeFirst() }
    while let last = tokens.last, filler.contains(last) { tokens.removeLast() }

    guard let candidate = tokens.last else { return nil }
    return WordNormalizer.normalize(candidate)
  }

  /// "it", "that word" — references to something already discussed, not a word to
  /// look up. Prefetching these would fire a dictionary lookup for the literal "it".
  static func isAnaphoric(_ raw: String) -> Bool {
    let t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    return ["it", "that", "this", "that word", "this word", "the word", "it again"].contains(t)
  }
}
