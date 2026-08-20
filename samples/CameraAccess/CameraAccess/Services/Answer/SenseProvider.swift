//
// SenseProvider.swift
//
// Supplies the candidate meanings that ground every answer.
//
// This is the piece that makes a 1.7B model trustworthy. Asked to *recall* what
// "perfunctory" means, a small model will invent something plausible and wrong.
// Handed four numbered senses from a dictionary and asked which one fits the reader's
// sentence, it does well — selection is an easy task, recall is not.
//
// Lookup order is chosen so the common case costs nothing:
//   1. A definition already stored on the reader's CapturedWord (they asked before)
//   2. The on-disk cache
//   3. dictionaryapi.dev
//   4. Nothing — the answer proceeds ungrounded and is forced to low confidence
//
// Step 4 is deliberately still an answer. A reader mid-sentence with no signal is
// better served by "here's my best guess, marked uncertain" than by silence.
//

import Foundation

actor SenseProvider {

  static let shared = SenseProvider()

  private let service = DefinitionService()
  private let cache = DefinitionCache.shared

  /// In-flight lookups, so a speculative prefetch and the real request for the same
  /// word don't both hit the network.
  private var inFlight: [String: Task<[DictionarySense], Never>] = [:]

  // MARK: - Lookup

  /// Candidate senses for a word. Never throws: an empty result is a valid outcome
  /// meaning "answer ungrounded, mark it low confidence".
  func senses(for word: String, existingDefinition: String? = nil) async -> [DictionarySense] {
    let key = Self.key(word)

    if let cached = await cache.senses(for: key), !cached.isEmpty {
      return cached
    }

    if let running = inFlight[key] {
      return await running.value
    }

    let task = Task<[DictionarySense], Never> { [service, cache] in
      do {
        let fetched = try await service.lookUpSenses(word: key)
        await cache.store(fetched, for: key)
        return fetched
      } catch {
        return []
      }
    }
    inFlight[key] = task
    let result = await task.value
    inFlight[key] = nil

    if !result.isEmpty { return result }

    // Offline or unknown word: fall back to whatever the reader already has stored,
    // so a previously-looked-up word still answers without a network.
    if let existing = existingDefinition, !existing.isEmpty {
      return [Self.senseFromStoredDefinition(existing)]
    }
    return []
  }

  /// Fire-and-forget warm-up, called the moment a candidate word is spotted in a
  /// *partial* transcript. By the time the reader stops speaking the dictionary leg
  /// is usually already done, which removes 150-400ms from the critical path.
  nonisolated func prefetch(_ word: String) {
    Task { _ = await self.senses(for: word) }
  }

  /// Flush the cache to disk. Called at session end.
  func flush() async {
    await cache.flush()
  }

  // MARK: - Helpers

  private static func key(_ word: String) -> String {
    WordNormalizer.normalize(word)
      ?? word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// Reconstructs a single sense from a stored "(noun) meaning" string so offline
  /// answers can still be grounded in something the reader previously saw.
  private static func senseFromStoredDefinition(_ stored: String) -> DictionarySense {
    var partOfSpeech = ""
    var definition = stored

    if stored.hasPrefix("("), let close = stored.firstIndex(of: ")") {
      partOfSpeech = String(stored[stored.index(after: stored.startIndex)..<close])
      definition = String(stored[stored.index(after: close)...])
        .trimmingCharacters(in: .whitespaces)
    }

    return DictionarySense(
      id: 1,
      partOfSpeech: partOfSpeech,
      definition: definition,
      example: nil,
      phonetic: nil
    )
  }
}
