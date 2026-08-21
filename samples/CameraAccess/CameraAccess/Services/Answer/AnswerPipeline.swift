//
// AnswerPipeline.swift
//
// One spoken question in, one spoken answer out. That's the entire job.
//
// The reader's words go to the model verbatim — no routing, no extraction, no
// classification. The only preparation is free: if the dictionary prefetch (fired
// while the reader was still talking) already has senses cached for a word in the
// utterance, they ride along as a single prompt line. The answer never waits on a
// lookup.
//
// Word capture is a separate step BEHIND the answer, never inside it. handle()
// owns the latency path and touches nothing slow; captureWord() runs after the
// answer is already sounding, where a dictionary network round trip costs the
// reader nothing. Folding capture into the answer was how the previous design
// accreted three layers of machinery — the separation is the lesson, kept.
//

import Foundation
import SwiftData
import os

@MainActor
final class AnswerPipeline {

  // MARK: - Result

  struct TurnResult {
    /// Everything spoken, joined — for the transcript and the answer card.
    let spokenText: String
    /// End of the pipeline's work to the first clause handed to TTS.
    let timeToFirstAudio: TimeInterval?
    let totalTime: TimeInterval
    /// Context to carry into the next turn.
    let context: SessionContext
  }

  // MARK: - Dependencies

  private let engine: AnswerEngine
  private let tts: TTSEngine
  private let senseProvider: SenseProvider
  private let definitionCache: DefinitionCache

  private let persistence: WordPersistenceService?

  init(
    engine: AnswerEngine = LlamaAnswerEngine.shared,
    tts: TTSEngine,
    senseProvider: SenseProvider = .shared,
    definitionCache: DefinitionCache = .shared,
    modelContext: ModelContext? = nil
  ) {
    self.engine = engine
    self.tts = tts
    self.senseProvider = senseProvider
    self.definitionCache = definitionCache
    self.persistence = modelContext.map(WordPersistenceService.init)
  }

  // MARK: - Entry point

  func handle(
    utterance: String,
    context: SessionContext,
    onFirstAudio: (@MainActor () -> Void)? = nil
  ) async throws -> TurnResult {

    let started = Date()

    let word = IntentRouter.likelyTargetWord(in: utterance)
    let prompt = AnswerPrompt(
      utterance: utterance,
      history: context.priorTurns,
      dictionaryLine: await cachedDictionaryLine(for: word),
      priorPhraseLine: priorPhraseLine(for: word, currentUtterance: utterance),
      bookTitle: context.bookTitle
    )

    var spoken: [String] = []
    var firstAudio: Date?
    var finalText = ""

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

      case .final(let text):
        finalText = text
      }
    }

    let answerText = finalText.isEmpty ? spoken.joined(separator: " ") : finalText

    var next = context
    next.priorTurns.append(ChatTurn(role: .user, content: utterance))
    next.priorTurns.append(ChatTurn(role: .assistant, content: answerText))
    next.priorTurns = Array(next.priorTurns.suffix(6))

    Log.answer.info("turn complete in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms")

    return TurnResult(
      spokenText: answerText,
      timeToFirstAudio: firstAudio.map { $0.timeIntervalSince(started) },
      totalTime: Date().timeIntervalSince(started),
      context: next
    )
  }

  /// Warm the dictionary for a word spotted in a partial transcript, so the senses
  /// are cached by the time the reader finishes their sentence.
  nonisolated func prefetch(_ word: String) {
    senseProvider.prefetch(word)
  }

  // MARK: - Word capture

  /// Files the word a turn was about into the vocabulary book. Call AFTER the
  /// answer — this is allowed to be slow (it may hit the dictionary network), which
  /// is exactly why it is not part of `handle()`.
  ///
  /// The word comes from the reader's utterance, not from the model: it is almost
  /// always verbatim there, and asking a model to repeat back something the app
  /// already heard is how latency was lost last time. No word found means the turn
  /// wasn't about a word — a follow-up, a chat — and nothing is filed, which is
  /// correct: the vocabulary book is words the reader asked about, not a log.
  func captureWord(from utterance: String, book: Book?) async -> CapturedWord? {
    guard let persistence else { return nil }
    guard let word = IntentRouter.likelyTargetWord(in: utterance) else { return nil }

    let existing = try? persistence.fetch(word)
    // Full sense lookup, network included — off the latency path by construction.
    let senses = await senseProvider.senses(for: word, existingDefinition: existing?.definition)

    do {
      // gloss deliberately nil: the dictionary's definition reads better in a word
      // list than a transcribed spoken answer does. The spoken answer's job was the
      // moment; the dictionary's job is the record.
      let outcome = try persistence.persist(
        word: word,
        gloss: nil,
        sense: senses.first,
        contextSentence: nil,
        book: book,
        spokenUtterance: utterance
      )
      Log.answer.info("captured \"\(outcome.word.text, privacy: .public)\" (\(outcome.isNew ? "new" : "enriched", privacy: .public))")
      return outcome.word
    } catch {
      Log.answer.error("word capture failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  // MARK: - Grounding

  /// The one line of dictionary context, from cache only.
  ///
  /// Cache-only is the point: this line is a free upgrade when the prefetch already
  /// paid for it, and skipped otherwise. A network wait here would put the dictionary
  /// back on the latency path the redesign just took it off.
  private func cachedDictionaryLine(for word: String?) async -> String? {
    guard let word else { return nil }
    guard let senses = await definitionCache.senses(for: word), !senses.isEmpty else {
      Log.answer.debug("no cached senses for \"\(word, privacy: .public)\" — answering ungrounded")
      return nil
    }
    Log.answer.info("grounded \"\(word, privacy: .public)\" from cache — \(senses.count, privacy: .public) senses")
    return PromptBuilder.dictionaryLine(word: word, senses: senses)
  }

  /// The one line of personal context: the reader has met this word before, and
  /// this is what they said then. Local SwiftData fetch — microseconds, no network.
  private func priorPhraseLine(for word: String?, currentUtterance: String) -> String? {
    guard let word, let persistence,
          let existing = try? persistence.fetch(word),
          let prior = existing.spokenUtterance,
          !prior.isEmpty, prior != currentUtterance else { return nil }
    return "When they last asked about this word, they said: \"\(prior)\""
  }
}
