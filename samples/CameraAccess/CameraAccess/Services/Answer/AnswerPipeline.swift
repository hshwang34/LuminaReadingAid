//
// AnswerPipeline.swift
//
// One spoken question in, one spoken answer plus a saved word out.
//
// The pipeline owns the ordering that makes the latency budget work: route
// deterministically (microseconds), ground from cache or dictionary, generate under a
// grammar, and hand each clause to TTS the instant it exists rather than when the
// answer is complete. Time-to-first-audio is measured here because it is the number
// the whole design is accountable to.
//
// Two intents never reach the model at all. Pronunciation comes from dictionary
// phonetics — a language model asked for IPA will confidently invent stress patterns.
// "Say that again" replays what was already produced. Both are instant and correct,
// which is a better outcome than a fast wrong one.
//

import Foundation
import os
import SwiftData

@MainActor
final class AnswerPipeline {

  // MARK: - Result

  struct TurnResult {
    let intent: SessionIntent
    let answer: GroundedAnswer?
    let followUp: FollowUpAnswer?
    /// Everything that was spoken, joined — for transcripts and "say that again".
    let spokenText: String
    let senses: [DictionarySense]
    let capturedWord: CapturedWord?
    /// End of the pipeline's work to the first clause handed to TTS.
    let timeToFirstAudio: TimeInterval?
    let totalTime: TimeInterval
    /// Context to carry into the next turn.
    let context: SessionContext
  }

  // MARK: - Dependencies

  private let engine: AnswerEngine
  private let tts: TTSEngine
  private let router: IntentRouting
  private let senseProvider: SenseProvider
  private let persistence: WordPersistenceService

  init(
    engine: AnswerEngine = LlamaAnswerEngine.shared,
    tts: TTSEngine,
    router: IntentRouting? = nil,
    senseProvider: SenseProvider = .shared,
    modelContext: ModelContext
  ) {
    self.engine = engine
    self.tts = tts
    // The router's fallback was designed in from the start and then never wired up,
    // which quietly demoted every unrecognised phrasing to "unintelligible". Regex
    // still answers the common shapes in microseconds; the model only sees the
    // misses, under a grammar that admits nothing but a valid classification.
    self.router = router ?? IntentRouter(llmFallback: Self.classifyWithModel(engine))
    self.senseProvider = senseProvider
    self.persistence = WordPersistenceService(context: modelContext)
  }

  /// The LLM leg of routing: ask the model what the reader meant.
  private static func classifyWithModel(_ engine: AnswerEngine) -> IntentRouter.LLMFallback {
    { utterance, context in
      let prompt = AnswerPrompt(mode: .intentClassification, utterance: utterance)
      do {
        for try await event in engine.generate(prompt) {
          if case .final(.classified(let classified)) = event {
            Log.answer.info("llm classified \"\(utterance, privacy: .public)\" → \(classified.intent, privacy: .public) \"\(classified.word, privacy: .public)\"")
            return IntentRouter.intent(
              fromClassified: classified, utterance: utterance, context: context
            )
          }
        }
      } catch {
        Log.answer.error("llm classification failed: \(error.localizedDescription, privacy: .public)")
      }
      return nil
    }
  }

  // MARK: - Entry point

  /// - Parameter onFirstAudio: called the instant the first clause is handed to the
  ///   synthesiser. The session UI needs this because generation and speech overlap:
  ///   by the time this method returns, Luna has usually been talking for a second or
  ///   more, and a UI that waits for the return value shows "thinking" over audible
  ///   speech.
  func handle(
    utterance: String,
    context: SessionContext,
    book: Book? = nil,
    onFirstAudio: (@MainActor () -> Void)? = nil
  ) async throws -> TurnResult {

    let started = Date()
    let intent = await router.route(utterance, context: context)
    Log.answer.info("routed \"\(utterance, privacy: .public)\" → \(String(describing: intent), privacy: .public)")

    switch intent {
    case .define(let word, let contextSentence):
      return try await generateGrounded(
        mode: .define, word: word, utterance: utterance,
        contextSentence: contextSentence, intent: intent,
        context: context, book: book, started: started,
        onFirstAudio: onFirstAudio
      )

    case .exampleSentence(let word):
      return try await generateGrounded(
        mode: .exampleSentence, word: word, utterance: utterance,
        contextSentence: nil, intent: intent,
        context: context, book: book, started: started,
        onFirstAudio: onFirstAudio
      )

    case .pronounce(let word):
      return try await pronounce(word, intent: intent, context: context,
                                 book: book, started: started,
                                 onFirstAudio: onFirstAudio)

    case .repeatLast:
      return await repeatLast(intent: intent, context: context, started: started,
                              onFirstAudio: onFirstAudio)

    case .followUp(let question):
      return try await generateFollowUp(
        question: question, intent: intent, context: context, started: started,
        onFirstAudio: onFirstAudio
      )

    case .endSession, .unintelligible:
      return TurnResult(
        intent: intent, answer: nil, followUp: nil, spokenText: "",
        senses: [], capturedWord: nil, timeToFirstAudio: nil,
        totalTime: Date().timeIntervalSince(started), context: context
      )
    }
  }

  /// Warm the dictionary for a word spotted in a partial transcript.
  nonisolated func prefetch(_ word: String) {
    senseProvider.prefetch(word)
  }

  // MARK: - Grounded answers

  private func generateGrounded(
    mode: AnswerPrompt.Mode,
    word: String,
    utterance: String,
    contextSentence: String?,
    intent: SessionIntent,
    context: SessionContext,
    book: Book?,
    started: Date,
    onFirstAudio: (@MainActor () -> Void)?
  ) async throws -> TurnResult {

    let existing = try? persistence.fetch(word)
    let senses = await senseProvider.senses(for: word, existingDefinition: existing?.definition)
    Log.answer.info("grounded \"\(word, privacy: .public)\" — \(senses.count, privacy: .public) senses")

    let prompt = AnswerPrompt(
      mode: mode,
      word: word,
      utterance: utterance,
      contextSentence: contextSentence,
      candidateSenses: senses,
      targetSenseID: mode == .exampleSentence ? context.lastAnswerSenseID : nil,
      bookTitle: book?.title ?? context.bookTitle
    )

    var spoken: [String] = []
    var firstAudio: Date?
    var answer: GroundedAnswer?

    for try await event in engine.generate(prompt) {
      switch event {
      case .speakable(let clause):
        if firstAudio == nil {
          firstAudio = Date()
          Log.answer.info("first audio at \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms")
          onFirstAudio?()
        }
        tts.enqueue(clause)
        spoken.append(clause)

      case .field:
        break  // the session UI observes these; the pipeline doesn't need them

      case .final(let outcome):
        if case .grounded(let value) = outcome { answer = value }
      }
    }

    // The model picked a sense; that's the one worth storing alongside the word.
    let chosen = answer.flatMap { a in senses.first { $0.id == a.senseID } }

    let outcome = try persistence.persist(
      word: word,
      answer: answer,
      sense: chosen ?? senses.first,
      contextSentence: contextSentence,
      book: book
    )
    Log.answer.info("turn complete in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms — sense \(answer?.senseID ?? -1, privacy: .public), \(outcome.isNew ? "inserted" : "enriched existing", privacy: .public) \"\(outcome.word.text, privacy: .public)\"")

    var next = context
    next.lastAnswerWord = word
    next.lastAnswerSenseID = answer?.senseID
    if !next.recentWords.contains(word) { next.recentWords.append(word) }
    next.priorTurns.append(ChatTurn(role: .user, content: utterance))
    next.priorTurns.append(ChatTurn(role: .assistant, content: spoken.joined(separator: " ")))
    next.priorTurns = Array(next.priorTurns.suffix(6))

    return TurnResult(
      intent: intent, answer: answer, followUp: nil,
      spokenText: spoken.joined(separator: " "),
      senses: senses, capturedWord: outcome.word,
      timeToFirstAudio: firstAudio.map { $0.timeIntervalSince(started) },
      totalTime: Date().timeIntervalSince(started),
      context: next
    )
  }

  // MARK: - Follow-up

  private func generateFollowUp(
    question: String,
    intent: SessionIntent,
    context: SessionContext,
    started: Date,
    onFirstAudio: (@MainActor () -> Void)?
  ) async throws -> TurnResult {

    let prompt = AnswerPrompt(
      mode: .followUp,
      word: context.lastAnswerWord,
      utterance: question,
      history: context.priorTurns,
      bookTitle: context.bookTitle
    )

    var spoken: [String] = []
    var firstAudio: Date?
    var answer: FollowUpAnswer?

    for try await event in engine.generate(prompt) {
      switch event {
      case .speakable(let clause):
        if firstAudio == nil {
          firstAudio = Date()
          Log.answer.info("first audio at \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms")
          onFirstAudio?()
        }
        tts.enqueue(clause)
        spoken.append(clause)
      case .field:
        break
      case .final(let outcome):
        if case .followUp(let value) = outcome { answer = value }
      }
    }

    var next = context
    next.priorTurns.append(ChatTurn(role: .user, content: question))
    next.priorTurns.append(ChatTurn(role: .assistant, content: spoken.joined(separator: " ")))
    next.priorTurns = Array(next.priorTurns.suffix(6))

    return TurnResult(
      intent: intent, answer: nil, followUp: answer,
      spokenText: spoken.joined(separator: " "),
      senses: [], capturedWord: nil,
      timeToFirstAudio: firstAudio.map { $0.timeIntervalSince(started) },
      totalTime: Date().timeIntervalSince(started),
      context: next
    )
  }

  // MARK: - Model-free intents

  private func pronounce(
    _ word: String,
    intent: SessionIntent,
    context: SessionContext,
    book: Book?,
    started: Date,
    onFirstAudio: (@MainActor () -> Void)?
  ) async throws -> TurnResult {

    let existing = try? persistence.fetch(word)
    let senses = await senseProvider.senses(for: word, existingDefinition: existing?.definition)

    let firstAudio = Date()
    onFirstAudio?()
    await tts.speakWordSlowly(word)

    // Asking how to say a word is still asking about it — file it.
    let outcome = try? persistence.persist(
      word: word, answer: nil, sense: senses.first,
      contextSentence: nil, book: book
    )

    var next = context
    next.lastAnswerWord = word

    return TurnResult(
      intent: intent, answer: nil, followUp: nil, spokenText: word,
      senses: senses, capturedWord: outcome?.word,
      timeToFirstAudio: firstAudio.timeIntervalSince(started),
      totalTime: Date().timeIntervalSince(started),
      context: next
    )
  }

  private func repeatLast(
    intent: SessionIntent,
    context: SessionContext,
    started: Date,
    onFirstAudio: (@MainActor () -> Void)?
  ) async -> TurnResult {

    let text = context.priorTurns.last(where: { $0.role == .assistant })?.content ?? ""
    let firstAudio: Date? = text.isEmpty ? nil : Date()
    if !text.isEmpty {
      onFirstAudio?()
      tts.enqueue(text)
    }

    return TurnResult(
      intent: intent, answer: nil, followUp: nil, spokenText: text,
      senses: [], capturedWord: nil,
      timeToFirstAudio: firstAudio.map { $0.timeIntervalSince(started) },
      totalTime: Date().timeIntervalSince(started),
      context: context
    )
  }
}
