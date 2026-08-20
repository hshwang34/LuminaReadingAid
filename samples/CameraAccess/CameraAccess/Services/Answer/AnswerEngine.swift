//
// AnswerEngine.swift
//
// Contracts for the grounded answer pipeline: the types that flow between the
// voice session and whichever LLM backend is generating answers.
//
// Design notes:
//
//  - Answers are GROUNDED, never free recall. The pipeline looks a word up in a
//    dictionary first and hands the model 3-5 candidate senses; the model's job
//    is to SELECT the sense that fits the reader's sentence and rephrase it
//    simply. Selection is a task a 1.7B model does well; recall is not.
//
//  - Output is grammar-constrained (GBNF on llama.cpp) so the model physically
//    cannot emit malformed JSON. `AnswerSchema` is the single source of truth for
//    both the grammar and the equivalent JSON Schema.
//
//  - Nothing here imports a model runtime. `AnswerEngine` is the seam that lets
//    the backend be swapped without touching the pipeline, the session, or the UI.
//
//  - Nothing here touches SwiftData. `SessionContext` carries only value types so
//    it can cross actor boundaries; the `Book` itself stays on the main actor and
//    is handed to `WordPersistenceService` separately.
//

import Foundation

// MARK: - Conversation

/// A single turn of conversation held by the answer pipeline.
///
/// Deliberately distinct from `ChatMessage` in `OnDeviceLLMService`: that type lives
/// in a file that imports MLX and is scheduled for retirement, and the Answer layer
/// must not depend on it.
struct ChatTurn: Sendable, Equatable {
  enum Role: String, Sendable, Equatable { case system, user, assistant }
  let role: Role
  let content: String

  init(role: Role, content: String) {
    self.role = role
    self.content = content
  }
}

// MARK: - Session context

/// Everything the answer pipeline knows about the reading session, in value form.
struct SessionContext: Sendable, Equatable {
  /// Title of the bound book, used only as a light prompt hint.
  var bookTitle: String?
  /// Words already asked about this session, most recent last.
  var recentWords: [String]
  /// Short rolling history for follow-up questions (capped by the pipeline).
  var priorTurns: [ChatTurn]
  /// The word the last answer was about — resolves "it" / "that word" / bare "example".
  var lastAnswerWord: String?
  /// The sense chosen for `lastAnswerWord`, so example requests stay on the same meaning.
  var lastAnswerSenseID: Int?

  init(
    bookTitle: String? = nil,
    recentWords: [String] = [],
    priorTurns: [ChatTurn] = [],
    lastAnswerWord: String? = nil,
    lastAnswerSenseID: Int? = nil
  ) {
    self.bookTitle = bookTitle
    self.recentWords = recentWords
    self.priorTurns = priorTurns
    self.lastAnswerWord = lastAnswerWord
    self.lastAnswerSenseID = lastAnswerSenseID
  }

  static let empty = SessionContext()
}

// MARK: - Answer payload

/// The validated result of one answer turn.
struct GroundedAnswer: Codable, Sendable, Equatable {
  enum Confidence: String, Codable, Sendable, Equatable {
    case high, medium, low
  }

  /// Index into the candidate senses that were shown to the model.
  /// `0` means "none of the listed senses fit".
  let senseID: Int
  /// The meaning rephrased for a learner. Short enough to speak in one breath.
  let shortGloss: String
  /// One example sentence using the word in the chosen sense.
  let example: String
  /// Gates the "in your sentence it means…" row in the UI. Low confidence never
  /// asserts a correction — it points the reader at the full sense list instead.
  let confidence: Confidence

  enum CodingKeys: String, CodingKey {
    case senseID = "sense_id"
    case shortGloss = "short_gloss"
    case example
    case confidence
  }
}

/// The validated result of a follow-up turn, which is conversational rather than
/// sense-selection shaped.
struct FollowUpAnswer: Codable, Sendable, Equatable {
  let answer: String
  let confidence: GroundedAnswer.Confidence
}

// MARK: - Streaming

/// A structured field completed by the incremental scanner, surfaced so the UI can
/// render the answer as it arrives rather than after it finishes.
enum AnswerField: Sendable, Equatable {
  case senseID(Int)
  case gloss(String)
  case example(String)
  case confidence(GroundedAnswer.Confidence)
  case followUpAnswer(String)
}

/// The final validated payload of a turn.
enum AnswerOutcome: Sendable, Equatable {
  case grounded(GroundedAnswer)
  case followUp(FollowUpAnswer)
  case classified(ClassifiedIntent)
}

/// The model's reading of an utterance the deterministic router could not place.
/// Grammar-constrained, so `intent` is always one of the known labels.
struct ClassifiedIntent: Codable, Sendable, Equatable {
  let intent: String
  let word: String
}

enum AnswerStreamEvent: Sendable, Equatable {
  /// A clause ready to be handed to TTS immediately. This is what keeps
  /// time-to-first-audio inside the latency budget: speech starts while the rest
  /// of the answer is still generating.
  case speakable(String)
  /// A structured field finished parsing — drives live UI updates.
  case field(AnswerField)
  /// The turn completed and validated.
  case final(AnswerOutcome)
}

// MARK: - Prompt

/// A fully-formed request to the model. Prompts are deliberately tiny; the system
/// prompt is byte-identical every turn so the backend can reuse its prefix/KV cache.
struct AnswerPrompt: Sendable, Equatable {
  enum Mode: Sendable, Equatable {
    /// Pick the sense that fits and rephrase it.
    case define
    /// Write a fresh example sentence for an already-chosen sense.
    case exampleSentence
    /// Conversational follow-up about the last answer.
    case followUp
    /// Classify an utterance the deterministic router could not place.
    case intentClassification
  }

  let mode: Mode
  let word: String?
  let utterance: String
  /// The reader's own sentence, when they spoke one.
  let contextSentence: String?
  /// Candidate senses shown to the model. Empty for follow-up and offline modes.
  let candidateSenses: [DictionarySense]
  /// The sense to write an example for (`exampleSentence` mode).
  let targetSenseID: Int?
  /// Rolling history, follow-up mode only.
  let history: [ChatTurn]
  /// The reader's own past example sentences, injected to make examples feel familiar.
  let personalExamples: [String]
  let bookTitle: String?

  init(
    mode: Mode,
    word: String? = nil,
    utterance: String,
    contextSentence: String? = nil,
    candidateSenses: [DictionarySense] = [],
    targetSenseID: Int? = nil,
    history: [ChatTurn] = [],
    personalExamples: [String] = [],
    bookTitle: String? = nil
  ) {
    self.mode = mode
    self.word = word
    self.utterance = utterance
    self.contextSentence = contextSentence
    self.candidateSenses = candidateSenses
    self.targetSenseID = targetSenseID
    self.history = history
    self.personalExamples = personalExamples
    self.bookTitle = bookTitle
  }
}

// MARK: - Engine

enum AnswerEngineError: LocalizedError, Equatable {
  case modelUnavailable
  case modelLoadFailed(String)
  case generationFailed(String)
  case invalidOutput
  case cancelled

  var errorDescription: String? {
    switch self {
    case .modelUnavailable: "The language model isn't ready yet."
    case .modelLoadFailed(let detail): "Couldn't load the language model. \(detail)"
    case .generationFailed(let detail): "Couldn't generate an answer. \(detail)"
    case .invalidOutput: "The model returned something unreadable."
    case .cancelled: "Cancelled."
    }
  }
}

/// Progress of the one-time model acquisition, surfaced by `ModelLoadingView`.
enum AnswerEngineReadiness: Sendable, Equatable {
  case notReady
  case downloading(progress: Double)
  case loading
  case ready
  case failed(String)
}

protocol AnswerEngine: Sendable {
  var readiness: AnswerEngineReadiness { get async }

  /// Acquire and load the model. Safe to call repeatedly; later calls are no-ops
  /// once ready. Called at session start so the first question isn't charged for it.
  func prepare(onProgress: @Sendable @escaping (AnswerEngineReadiness) -> Void) async throws

  /// Generate one answer turn. The stream yields speakable clauses as soon as they
  /// exist, structured fields as they parse, and exactly one `.final` event.
  func generate(_ prompt: AnswerPrompt) -> AsyncThrowingStream<AnswerStreamEvent, Error>

  /// Barge-in: abandon the in-flight generation.
  func cancelCurrent() async
}

// MARK: - Schema (single source of truth for both backends)

/// The output contract. `grammar` constrains llama.cpp at the sampling layer so
/// malformed output is impossible; `jsonSchema` is the same contract expressed for
/// backends that can only validate after the fact.
enum AnswerSchema {

  /// Keys in the exact order the model must emit them. The scanner relies on this
  /// order: `short_gloss` comes early so speech can start before `example` finishes.
  static let groundedKeys: [StreamingJSONFieldScanner.ExpectedField] = [
    .init(key: "sense_id", isQuoted: false),
    .init(key: "short_gloss", isQuoted: true),
    .init(key: "example", isQuoted: true),
    .init(key: "confidence", isQuoted: true),
  ]

  static let followUpKeys: [StreamingJSONFieldScanner.ExpectedField] = [
    .init(key: "answer", isQuoted: true),
    .init(key: "confidence", isQuoted: true),
  ]

  static let intentKeys: [StreamingJSONFieldScanner.ExpectedField] = [
    .init(key: "intent", isQuoted: true),
    .init(key: "word", isQuoted: true),
  ]

  /// GBNF grammar for the grounded answer. Consumed by llama.cpp's grammar sampler.
  static let groundedGrammar = #"""
  root  ::= "{" ws "\"sense_id\"" ws ":" ws [0-5] ws "," ws "\"short_gloss\"" ws ":" ws str ws "," ws "\"example\"" ws ":" ws str ws "," ws "\"confidence\"" ws ":" ws conf ws "}"
  conf  ::= "\"high\"" | "\"medium\"" | "\"low\""
  str   ::= "\"" ([^"\\\x00-\x1F] | "\\" ["\\bfnrt/])* "\""
  ws    ::= [ \t\n]?
  """#

  /// GBNF grammar for a conversational follow-up.
  static let followUpGrammar = #"""
  root  ::= "{" ws "\"answer\"" ws ":" ws str ws "," ws "\"confidence\"" ws ":" ws conf ws "}"
  conf  ::= "\"high\"" | "\"medium\"" | "\"low\""
  str   ::= "\"" ([^"\\\x00-\x1F] | "\\" ["\\bfnrt/])* "\""
  ws    ::= [ \t\n]?
  """#

  /// GBNF grammar for intent classification — the primary router (user decision
  /// 2026-08-20: every utterance goes through the model; the regex table is only an
  /// emergency fallback when the model itself fails).
  static let intentGrammar = #"""
  root   ::= "{" ws "\"intent\"" ws ":" ws intent ws "," ws "\"word\"" ws ":" ws str ws "}"
  intent ::= "\"define\"" | "\"example\"" | "\"pronounce\"" | "\"repeat\"" | "\"followup\"" | "\"end\"" | "\"other\""
  str    ::= "\"" ([^"\\\x00-\x1F] | "\\" ["\\bfnrt/])* "\""
  ws     ::= [ \t\n]?
  """#

  /// Equivalent JSON Schema, for validation-only backends and for documentation.
  static let groundedJSONSchema = #"""
  {
    "type": "object",
    "properties": {
      "sense_id":    { "type": "integer", "minimum": 0, "maximum": 5 },
      "short_gloss": { "type": "string", "maxLength": 140 },
      "example":     { "type": "string", "maxLength": 120 },
      "confidence":  { "enum": ["high", "medium", "low"] }
    },
    "required": ["sense_id", "short_gloss", "example", "confidence"],
    "additionalProperties": false
  }
  """#

  // MARK: Sampling

  /// Answers are short by design: a spoken gloss plus one example. Capping tokens
  /// bounds both latency and the battery cost of a turn.
  static let maxAnswerTokens = 110
  static let maxFollowUpTokens = 80
  static let maxIntentTokens = 30
  /// Deterministic: this is a selection task, not a creative one.
  static let temperature: Float = 0.0
  /// Qwen3 non-thinking recommended sampling, used if temperature is ever raised.
  static let topP: Float = 0.8
  static let topK: Int = 20
}

// MARK: - Validation

extension GroundedAnswer {
  /// Clamps a model result into the range the UI and persistence layer can trust.
  ///
  /// Grammar constraints guarantee the SHAPE of the output; they cannot guarantee
  /// that `sense_id` refers to a sense that actually exists. An out-of-range id
  /// becomes "no sense fits" and drags confidence down with it.
  func validated(againstSenseCount count: Int) -> GroundedAnswer {
    var id = senseID
    var conf = confidence

    if id < 0 || id > count {
      id = 0
      conf = .low
    }
    if id == 0 {
      conf = .low
    }

    let gloss = shortGloss.trimmingCharacters(in: .whitespacesAndNewlines)
    let ex = example.trimmingCharacters(in: .whitespacesAndNewlines)

    if gloss.isEmpty {
      conf = .low
    }

    return GroundedAnswer(senseID: id, shortGloss: gloss, example: ex, confidence: conf)
  }
}
