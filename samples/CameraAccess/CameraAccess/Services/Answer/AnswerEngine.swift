//
// AnswerEngine.swift
//
// The contract for answering a reader, reduced to what a reader actually experiences.
//
// The pipeline used to run the model through structure — intent classification, a
// JSON contract, sense-id selection — and every layer existed for the pipeline's
// convenience rather than the reader's. Measured on device, that machinery cost two
// generations and six seconds per question. What survived the redesign is the whole
// of the contract: the reader's words go in verbatim, a short spoken answer streams
// out, clause by clause, and speech starts at the first clause.
//
// Grounding still exists, but as a prompt line, not a subsystem: when the dictionary
// prefetch has senses cached for a word in the utterance, they are handed to the
// model as one line of context it may use or ignore.
//

import Foundation

// MARK: - Conversation

/// One prior exchange, kept so "use it in a sentence" and "say that again" work the
/// way conversation works — from memory, without any routing machinery.
struct ChatTurn: Sendable, Equatable {
  enum Role: Sendable, Equatable { case user, assistant }
  let role: Role
  let content: String
}

/// What the answer path carries between turns. Deliberately tiny: rolling history
/// plus the book's title as light flavour for examples.
struct SessionContext: Sendable, Equatable {
  var bookTitle: String?
  /// Short rolling history, capped by the pipeline.
  var priorTurns: [ChatTurn]

  init(bookTitle: String? = nil, priorTurns: [ChatTurn] = []) {
    self.bookTitle = bookTitle
    self.priorTurns = priorTurns
  }

  static let empty = SessionContext()
}

// MARK: - Prompt

/// Everything one generation needs. The utterance is the reader's words verbatim —
/// nothing is extracted, classified, or rewritten on the way in.
struct AnswerPrompt: Sendable, Equatable {
  let utterance: String
  let history: [ChatTurn]
  /// One optional line of dictionary grounding, e.g.
  /// `Dictionary: divine — (v) to guess by intuition; (adj) godlike`.
  /// Present only when the prefetch already has it — never worth waiting for.
  let dictionaryLine: String?
  let bookTitle: String?

  init(
    utterance: String,
    history: [ChatTurn] = [],
    dictionaryLine: String? = nil,
    bookTitle: String? = nil
  ) {
    self.utterance = utterance
    self.history = history
    self.dictionaryLine = dictionaryLine
    self.bookTitle = bookTitle
  }
}

// MARK: - Stream

enum AnswerStreamEvent: Sendable, Equatable {
  /// A clause worth speaking, emitted the moment it is complete. The first of these
  /// is the latency number the whole design is accountable to.
  case speakable(String)
  /// The complete answer text, after generation finishes.
  case final(String)
}

// MARK: - Engine

enum AnswerEngineError: LocalizedError, Equatable {
  case modelUnavailable
  case modelLoadFailed(String)
  case generationFailed(String)
  case cancelled

  var errorDescription: String? {
    switch self {
    case .modelUnavailable: "The language model isn't loaded yet."
    case .modelLoadFailed(let detail): "The language model failed to load: \(detail)"
    case .generationFailed(let detail): "Answering failed: \(detail)"
    case .cancelled: "The answer was interrupted."
    }
  }
}

enum AnswerEngineReadiness: Sendable, Equatable {
  case notReady
  case downloading(progress: Double)
  case loading
  case ready
  case failed(String)
}

protocol AnswerEngine: Sendable {
  var readiness: AnswerEngineReadiness { get async }

  /// Ensures the model is on disk and in memory, reporting progress along the way.
  func prepare(onProgress: @Sendable @escaping (AnswerEngineReadiness) -> Void) async throws

  /// One utterance in, streamed speech out.
  func generate(_ prompt: AnswerPrompt) -> AsyncThrowingStream<AnswerStreamEvent, Error>

  /// Barge-in: abandon the in-flight generation.
  func cancelCurrent() async
}

// MARK: - Sampling

/// Qwen3's recommended non-thinking sampling. Prose needs variety; greedy decoding
/// of conversational text degenerates into repetition.
enum AnswerSampling {
  static let temperature: Float = 0.7
  static let topP: Float = 0.8
  static let topK: Int32 = 20
  /// Two short spoken sentences. The cap bounds latency and battery per turn.
  static let maxTokens = 90
}
