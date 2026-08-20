//
// IntentRouter.swift
//
// Decides what the reader actually asked for. Runs a deterministic pattern table
// first and only falls back to the model when nothing matches.
//
// Why deterministic-first: routing sits directly in the latency path, and the shapes
// people use to ask about a word are few and highly stereotyped. Regex routing costs
// microseconds and never hallucinates an intent; the model fallback costs ~300ms and
// is reserved for genuinely unusual phrasings.
//
// Matching is case-insensitive against the ORIGINAL utterance (not a lowercased copy)
// so a captured context sentence keeps its capitalisation for storage and display.
//

import Foundation

// MARK: - Intent

enum SessionIntent: Equatable, Sendable {
  /// "what does X mean" (optionally "… in <the reader's sentence>")
  case define(word: String, contextSentence: String?)
  /// "use X in a sentence"
  case exampleSentence(word: String)
  /// "how do you pronounce X" — answered from dictionary phonetics, never the model.
  case pronounce(word: String)
  /// "say that again" — re-speak the previous answer verbatim, no generation.
  case repeatLast
  /// A conversational question about the previous answer.
  case followUp(question: String)
  case endSession
  case unintelligible
}

protocol IntentRouting: Sendable {
  func route(_ utterance: String, context: SessionContext) async -> SessionIntent
}

// MARK: - Router

struct IntentRouter: IntentRouting {

  /// Optional model-backed classifier, injected by the pipeline. Kept optional so
  /// routing (and its tests) have no dependency on a model runtime.
  typealias LLMFallback = @Sendable (String, SessionContext) async -> SessionIntent?

  private let llmFallback: LLMFallback?

  init(llmFallback: LLMFallback? = nil) {
    self.llmFallback = llmFallback
  }

  func route(_ utterance: String, context: SessionContext) async -> SessionIntent {
    let cleaned = Self.clean(utterance)
    guard !cleaned.isEmpty else { return .unintelligible }

    if let intent = Self.deterministic(cleaned, context: context) {
      return intent
    }

    // Single-word utterances are almost always a misfire or a bare word; asking the
    // model to classify them wastes a turn.
    let wordCount = cleaned.split(separator: " ").count
    if wordCount >= 2, let fallback = llmFallback,
       let intent = await fallback(cleaned, context) {
      return intent
    }

    return .unintelligible
  }

  // MARK: Deterministic pass

  /// Exposed for tests and for the pipeline's fast path.
  static func deterministic(_ utterance: String, context: SessionContext) -> SessionIntent? {
    for rule in rules {
      guard let match = utterance.firstMatch(of: rule.regex) else { continue }
      let groups = (0..<match.count).map { index -> String? in
        match[index].substring.map(String.init)
      }
      if let intent = rule.build(groups, context) {
        return intent
      }
    }
    return followUpHeuristic(utterance, context: context)
  }

  /// A question with no extractable word, arriving right after an answer, is almost
  /// always about that answer.
  private static func followUpHeuristic(_ utterance: String, context: SessionContext) -> SessionIntent? {
    guard context.lastAnswerWord != nil else { return nil }
    let lower = utterance.lowercased()
    let opensAsQuestion = questionOpeners.contains { lower.hasPrefix($0 + " ") }
    let hasAnaphora = anaphora.contains { lower.contains($0) }
    guard opensAsQuestion || hasAnaphora else { return nil }
    return .followUp(question: utterance)
  }

  private static let questionOpeners = [
    "what", "why", "how", "is", "are", "was", "were", "can", "could",
    "does", "do", "did", "and", "but", "so", "which", "when",
  ]

  private static let anaphora = [" it ", " it?", " that word", " this word", " that one"]

  // MARK: Rules

  private struct Rule {
    let regex: Regex<AnyRegexOutput>
    let build: (_ groups: [String?], _ context: SessionContext) -> SessionIntent?
  }

  /// Order matters: the most specific shapes are tested first so that, for example,
  /// "use it in a sentence" is not swallowed by a define pattern.
  private static let rules: [Rule] = {
    func rx(_ pattern: String) -> Regex<AnyRegexOutput> {
      // Patterns are compile-time literals covered by IntentRouterTests, so a failure
      // here is a build-time authoring bug rather than a runtime condition.
      try! Regex(pattern).ignoresCase()
    }

    return [
      // ── End session ────────────────────────────────────────────────────────
      Rule(regex: rx(#"^(?:stop|end|finish|done|quit|exit)$"#)) { _, _ in .endSession },
      Rule(regex: rx(#"^(?:that'?s (?:all|it)|good ?bye|bye|good ?night)\b"#)) { _, _ in .endSession },
      Rule(regex: rx(#"\b(?:end|stop|finish|close) (?:the |this )?(?:session|reading)\b"#)) { _, _ in .endSession },
      Rule(regex: rx(#"^stop listening\b"#)) { _, _ in .endSession },

      // ── Repeat ─────────────────────────────────────────────────────────────
      Rule(regex: rx(#"^(?:can you )?(?:say|repeat) (?:it|that)(?: again)?[?.]?$"#)) { _, _ in .repeatLast },
      Rule(regex: rx(#"^(?:repeat|again)[?.]?$"#)) { _, _ in .repeatLast },
      Rule(regex: rx(#"^(?:one more time|come again)[?.]?$"#)) { _, _ in .repeatLast },

      // ── Pronounce ──────────────────────────────────────────────────────────
      Rule(regex: rx(#"how (?:do|would|should) (?:you|i|we) (?:say|pronounce) (.+)"#)) { g, ctx in
        resolveWord(g[safe: 1] ?? nil, context: ctx).map { SessionIntent.pronounce(word: $0) }
      },
      Rule(regex: rx(#"^(?:can you )?pronounce (.+)"#)) { g, ctx in
        resolveWord(g[safe: 1] ?? nil, context: ctx).map { SessionIntent.pronounce(word: $0) }
      },
      Rule(regex: rx(#"how(?:'s| is) (.+?) pronounced"#)) { g, ctx in
        resolveWord(g[safe: 1] ?? nil, context: ctx).map { SessionIntent.pronounce(word: $0) }
      },

      // ── Example sentence ───────────────────────────────────────────────────
      Rule(regex: rx(#"use (?:the word )?(.+?) in a sentence"#)) { g, ctx in
        resolveWord(g[safe: 1] ?? nil, context: ctx).map { SessionIntent.exampleSentence(word: $0) }
      },
      Rule(regex: rx(#"(?:give|show|make|write) (?:me )?(?:an?|another) example(?: sentence)?(?: (?:with|of|for|using) (.+))?"#)) { g, ctx in
        resolveWord(g[safe: 1] ?? nil, context: ctx).map { SessionIntent.exampleSentence(word: $0) }
      },
      Rule(regex: rx(#"^(?:an?|another )?example(?: sentence)?[?.]?$"#)) { _, ctx in
        ctx.lastAnswerWord.map { SessionIntent.exampleSentence(word: $0) }
      },

      // ── Define ─────────────────────────────────────────────────────────────
      // The optional trailing group captures the reader's own sentence:
      //   "what does divine mean in she divines her way"
      Rule(regex: rx(#"what does (.+?) mean(?:\s+in\s+(?:this sentence[:,]?\s*)?(.+))?[?.]?$"#)) { g, ctx in
        guard let word = resolveWord(g[safe: 1] ?? nil, context: ctx) else { return nil }
        return .define(word: word, contextSentence: sentence(g[safe: 2] ?? nil))
      },
      Rule(regex: rx(#"what(?:'s| is| does) (?:the )?(?:meaning|definition) of (.+?)(?:\s+in\s+(.+))?[?.]?$"#)) { g, ctx in
        guard let word = resolveWord(g[safe: 1] ?? nil, context: ctx) else { return nil }
        return .define(word: word, contextSentence: sentence(g[safe: 2] ?? nil))
      },
      Rule(regex: rx(#"^(?:can you )?define (.+?)[?.]?$"#)) { g, ctx in
        resolveWord(g[safe: 1] ?? nil, context: ctx).map { SessionIntent.define(word: $0, contextSentence: nil) }
      },
      Rule(regex: rx(#"^what(?:'s| is) (?:an?|the word) (.+?)[?.]?$"#)) { g, ctx in
        resolveWord(g[safe: 1] ?? nil, context: ctx).map { SessionIntent.define(word: $0, contextSentence: nil) }
      },
      Rule(regex: rx(#"^(?:the )?meaning of (.+?)[?.]?$"#)) { g, ctx in
        resolveWord(g[safe: 1] ?? nil, context: ctx).map { SessionIntent.define(word: $0, contextSentence: nil) }
      },
      Rule(regex: rx(#"^(.+?) means what[?.]?$"#)) { g, ctx in
        resolveWord(g[safe: 1] ?? nil, context: ctx).map { SessionIntent.define(word: $0, contextSentence: nil) }
      },
      Rule(regex: rx(#"^what does (?:it|that|this word) mean[?.]?$"#)) { _, ctx in
        ctx.lastAnswerWord.map { SessionIntent.define(word: $0, contextSentence: nil) }
      },

      // ── Define, inverted and embedded forms ────────────────────────────────
      // "Can you explain what divine means?", "do you know what divine means?",
      // "tell me what divine means" — all carry the same inner clause, so one
      // unanchored rule covers the lot. It must sit before the bare `explain` rule:
      // "explain what divine means" would otherwise capture the whole clause and
      // extract "means" as the word.
      Rule(regex: rx(#"what (?:the word )?(.+?) means[?.]?$"#)) { g, ctx in
        resolveWord(g[safe: 1] ?? nil, context: ctx).map { SessionIntent.define(word: $0, contextSentence: nil) }
      },
      Rule(regex: rx(#"^(?:can you |could you |please )?explain (?:the word )?(.+?)[?.]?$"#)) { g, ctx in
        resolveWord(g[safe: 1] ?? nil, context: ctx).map { SessionIntent.define(word: $0, contextSentence: nil) }
      },
    ]
  }()

  // MARK: Extraction helpers

  /// Normalises an utterance for matching without destroying its casing.
  /// The word a partial utterance is probably heading toward, or nil.
  ///
  /// Used to start the dictionary lookup while the reader is still talking, so that by
  /// the time they stop the definition is already in memory and a network round trip
  /// has left the part of the latency budget they actually feel.
  ///
  /// Deliberately *not* the routing table. Routing waits for a complete sentence —
  /// "what does precision mean" only matches once "mean" arrives, by which point the
  /// reader has essentially finished and the head start is gone. These patterns fire
  /// on the lead-in instead, a second or two earlier, and accept being wrong more
  /// often: the cost of a bad guess is one cache entry nobody reads.
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

  /// Lead-in shapes, matched against an incomplete transcript. Each captures the first
  /// plausible word after a phrase that only ever precedes a lookup.
  private static let prefetchRules: [Regex<AnyRegexOutput>] = {
    func rx(_ pattern: String) -> Regex<AnyRegexOutput> {
      try! Regex(pattern).ignoresCase()
    }
    return [
      rx(#"\bwhat does (?:the word )?([\p{L}][\p{L}'’\-]+)"#),
      rx(#"\b(?:meaning|definition) of (?:the word )?([\p{L}][\p{L}'’\-]+)"#),
      rx(#"\bdefine (?:the word )?([\p{L}][\p{L}'’\-]+)"#),
      rx(#"\bpronounce (?:the word )?([\p{L}][\p{L}'’\-]+)"#),
      rx(#"\bhow(?:'s| is) ([\p{L}][\p{L}'’\-]+) pronounced"#),
      rx(#"\buse (?:the word )?([\p{L}][\p{L}'’\-]+)"#),
      rx(#"\bwhat(?:'s| is) (?:an?|the word) ([\p{L}][\p{L}'’\-]+)"#),
    ]
  }()

  static func clean(_ utterance: String) -> String {
    utterance
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
  }

  /// Pulls the target word out of a captured slot, falling back to the word the last
  /// answer was about when the slot is anaphoric ("it", "that word").
  static func resolveWord(_ raw: String?, context: SessionContext) -> String? {
    guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
      return context.lastAnswerWord
    }
    if isAnaphoric(raw) { return context.lastAnswerWord }
    return extractWord(from: raw) ?? context.lastAnswerWord
  }

  private static func isAnaphoric(_ raw: String) -> Bool {
    let t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    return ["it", "that", "this", "that word", "this word", "the word", "it again"].contains(t)
  }

  /// Filler that surrounds a spoken word slot and must not be mistaken for the word.
  private static let filler: Set<String> = [
    "the", "a", "an", "word", "term", "this", "that", "mean", "means",
    "meaning", "please", "again", "exactly", "actually", "really",
  ]

  /// Reduces a captured slot to a single dictionary-lookupable word.
  ///
  /// `WordNormalizer.normalize` keeps only the first whitespace-delimited token, which
  /// would turn "the word precision" into "the" — so filler is stripped first and the
  /// final remaining token is taken as the target.
  static func extractWord(from raw: String) -> String? {
    var tokens = raw
      .split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" && $0 != "-" })
      .map { $0.lowercased() }

    while let first = tokens.first, filler.contains(first) { tokens.removeFirst() }
    while let last = tokens.last, filler.contains(last) { tokens.removeLast() }

    guard let candidate = tokens.last else { return nil }
    return WordNormalizer.normalize(candidate)
  }

  /// Cleans a captured context sentence, discarding slots too short to be one.
  private static func sentence(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.split(separator: " ").count >= 3 else { return nil }
    return trimmed
  }
}

// MARK: - Utilities

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
