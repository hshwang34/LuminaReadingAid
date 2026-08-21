//
// WordPersistenceService.swift
//
// Turns an answered question into a row in the reader's vocabulary.
//
// Dedupe lives here because the app currently has none: the camera capture path
// inserts a new CapturedWord unconditionally, so asking about the same word twice
// produces two entries and corrupts the practice queue (a word could be scheduled
// twice at different mastery levels). The voice path must not repeat that, and this
// service is written so the camera path can adopt it later.
//
// Update semantics are deliberately conservative: an existing row is enriched, never
// overwritten. A word the reader captured weeks ago keeps its original capture date,
// its mastery progress and its starred state; only genuinely empty fields get filled.
//

import Foundation
import SwiftData

@MainActor
struct WordPersistenceService {

  enum Outcome {
    case inserted(CapturedWord)
    case updated(CapturedWord)

    var word: CapturedWord {
      switch self {
      case .inserted(let w), .updated(let w): w
      }
    }

    var isNew: Bool {
      if case .inserted = self { return true }
      return false
    }
  }

  let context: ModelContext

  init(context: ModelContext) {
    self.context = context
  }

  /// Persist the result of one answered question.
  ///
  /// Currently unused by the voice turn — capture left the answer path in the
  /// LM-native redesign and returns later as its own step behind the answer. The
  /// dedupe-and-enrich semantics here are the part worth keeping.
  ///
  /// - Parameters:
  ///   - word: already normalised by `WordNormalizer`.
  ///   - gloss: the spoken definition, when one was produced.
  ///   - sense: the dictionary sense that grounded the answer, if any.
  ///   - contextSentence: the reader's own spoken sentence, when they gave one.
  ///   - book: the session's bound book, if any.
  @discardableResult
  func persist(
    word: String,
    gloss: String?,
    sense: DictionarySense?,
    contextSentence: String?,
    book: Book?
  ) throws -> Outcome {

    let normalized = WordNormalizer.normalize(word) ?? word.lowercased()

    let definition = Self.formattedDefinition(gloss: gloss, sense: sense)
    let pronunciation = sense?.phonetic
    let example = sense?.example

    if let existing = try fetch(normalized) {
      enrich(
        existing,
        definition: definition,
        pronunciation: pronunciation,
        example: example,
        contextSentence: contextSentence,
        book: book
      )
      try context.save()
      return .updated(existing)
    }

    let created = CapturedWord(
      text: normalized,
      contextPhrase: contextSentence,
      book: book
    )
    created.definition = definition
    created.pronunciation = pronunciation
    created.exampleSentence = example

    context.insert(created)
    try context.save()
    return .inserted(created)
  }

  // MARK: - Lookup

  func fetch(_ normalizedWord: String) throws -> CapturedWord? {
    var descriptor = FetchDescriptor<CapturedWord>(
      predicate: #Predicate { $0.text == normalizedWord }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  // MARK: - Enrichment

  /// Fills only what is missing. Never clears a value the reader already has.
  private func enrich(
    _ word: CapturedWord,
    definition: String?,
    pronunciation: String?,
    example: String?,
    contextSentence: String?,
    book: Book?
  ) {
    if isBlank(word.definition), let definition, !definition.isEmpty {
      word.definition = definition
    }
    if isBlank(word.pronunciation), let pronunciation, !pronunciation.isEmpty {
      word.pronunciation = pronunciation
    }
    if isBlank(word.exampleSentence), let example, !example.isEmpty {
      word.exampleSentence = example
    }
    // A spoken sentence from the reader is better context than none, but an existing
    // one came from their own reading too — don't trample it.
    if isBlank(word.contextPhrase), let contextSentence, !contextSentence.isEmpty {
      word.contextPhrase = contextSentence
    }
    // Attaching the book late is how a word first captured outside a session gets
    // filed into the right shelf.
    if word.book == nil, let book {
      word.book = book
    }
  }

  private func isBlank(_ value: String?) -> Bool {
    guard let value else { return true }
    return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Matches the "(partOfSpeech) definition" shape the rest of the app already
  /// renders, so voice-captured and camera-captured words look identical in the list.
  static func formattedDefinition(gloss: String?, sense: DictionarySense?) -> String? {
    let trimmedGloss = gloss?.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = (trimmedGloss?.isEmpty == false ? trimmedGloss : sense?.definition)?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let text, !text.isEmpty else { return nil }

    if let pos = sense?.partOfSpeech, !pos.isEmpty {
      return "(\(pos)) \(text)"
    }
    return text
  }
}
