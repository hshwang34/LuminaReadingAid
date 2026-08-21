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
// Word capture into the vocabulary book is deliberately absent here. It is a
// separate concern from answering, and folding it into this path was how the
// previous design accreted three layers of machinery. It returns later as its own
// step, behind the answer, off the latency path.
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

  init(
    engine: AnswerEngine = LlamaAnswerEngine.shared,
    tts: TTSEngine,
    senseProvider: SenseProvider = .shared,
    definitionCache: DefinitionCache = .shared,
    modelContext: ModelContext? = nil  // kept for call-site stability; capture returns later
  ) {
    self.engine = engine
    self.tts = tts
    self.senseProvider = senseProvider
    self.definitionCache = definitionCache
  }

  // MARK: - Entry point

  func handle(
    utterance: String,
    context: SessionContext,
    onFirstAudio: (@MainActor () -> Void)? = nil
  ) async throws -> TurnResult {

    let started = Date()

    let prompt = AnswerPrompt(
      utterance: utterance,
      history: context.priorTurns,
      dictionaryLine: await cachedDictionaryLine(for: utterance),
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

  // MARK: - Grounding

  /// The one line of dictionary context, from cache only.
  ///
  /// Cache-only is the point: this line is a free upgrade when the prefetch already
  /// paid for it, and skipped otherwise. A network wait here would put the dictionary
  /// back on the latency path the redesign just took it off.
  private func cachedDictionaryLine(for utterance: String) async -> String? {
    guard let word = IntentRouter.likelyTargetWord(in: utterance) else { return nil }
    guard let senses = await definitionCache.senses(for: word), !senses.isEmpty else {
      Log.answer.debug("no cached senses for \"\(word, privacy: .public)\" — answering ungrounded")
      return nil
    }
    Log.answer.info("grounded \"\(word, privacy: .public)\" from cache — \(senses.count, privacy: .public) senses")
    return PromptBuilder.dictionaryLine(word: word, senses: senses)
  }
}
