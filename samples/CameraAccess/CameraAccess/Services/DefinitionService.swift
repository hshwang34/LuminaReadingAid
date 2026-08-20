import Foundation

struct WordDefinition {
  let definition: String
  let pronunciation: String
  let exampleSentence: String
}

/// One candidate meaning of a word, as offered to the model for selection.
///
/// The answer pipeline never asks the model to *recall* a definition — it hands it a
/// numbered list of these and asks which one fits the reader's sentence. `id` is the
/// number the model returns as `sense_id`, so it is 1-based (`0` means "none fit").
struct DictionarySense: Codable, Sendable, Identifiable, Equatable {
  /// 1-based; referenced by `GroundedAnswer.senseID`.
  let id: Int
  /// e.g. "adjective" — rendered as small-caps amber in the answer card.
  let partOfSpeech: String
  let definition: String
  let example: String?
  /// IPA from the dictionary. Pronunciation NEVER comes from the model.
  let phonetic: String?

  /// A shortened form for prompt construction — keeps the prompt tiny, which is
  /// what keeps prefill inside the latency budget.
  func promptLine(maxWords: Int = 12) -> String {
    let words = definition.split(separator: " ")
    let text = words.count <= maxWords
      ? definition
      : words.prefix(maxWords).joined(separator: " ") + "…"
    return partOfSpeech.isEmpty ? "\(id). \(text)" : "\(id). (\(partOfSpeech)) \(text)"
  }
}

actor DefinitionService {

  /// Returns up to `limit` candidate senses for a word, ordered as the dictionary
  /// orders them (most common first). Used to ground every answer.
  func lookUpSenses(word: String, limit: Int = 5) async throws -> [DictionarySense] {
    let entries = try await fetchEntries(word: word)

    let phonetic = entries.compactMap { entry in
      entry.phonetic ?? entry.phonetics?.first(where: { $0.text?.isEmpty == false })?.text
    }.first(where: { !$0.isEmpty })

    var senses: [DictionarySense] = []
    outer: for entry in entries {
      for meaning in entry.meanings ?? [] {
        let pos = meaning.partOfSpeech ?? ""
        for def in meaning.definitions ?? [] {
          guard let text = def.definition, !text.isEmpty else { continue }
          senses.append(
            DictionarySense(
              id: senses.count + 1,
              partOfSpeech: pos,
              definition: text,
              example: def.example?.isEmpty == false ? def.example : nil,
              phonetic: phonetic
            )
          )
          if senses.count >= limit { break outer }
        }
      }
    }

    guard !senses.isEmpty else { throw DefinitionError.notFound }
    return senses
  }

  private func fetchEntries(word: String) async throws -> [DictionaryEntry] {
    let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
          let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encoded)") else {
      throw DefinitionError.parseError
    }

    let (data, response) = try await URLSession.shared.data(from: url)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw DefinitionError.apiError
    }
    if httpResponse.statusCode == 404 {
      throw DefinitionError.notFound
    }
    guard httpResponse.statusCode == 200 else {
      throw DefinitionError.apiError
    }

    let entries = try JSONDecoder().decode([DictionaryEntry].self, from: data)
    guard !entries.isEmpty else { throw DefinitionError.notFound }
    return entries
  }

  func lookUp(word: String) async throws -> WordDefinition {
    let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
          let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encoded)") else {
      throw DefinitionError.parseError
    }

    let (data, response) = try await URLSession.shared.data(from: url)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw DefinitionError.apiError
    }

    if httpResponse.statusCode == 404 {
      throw DefinitionError.notFound
    }

    guard httpResponse.statusCode == 200 else {
      throw DefinitionError.apiError
    }

    let entries = try JSONDecoder().decode([DictionaryEntry].self, from: data)
    guard let entry = entries.first else {
      throw DefinitionError.notFound
    }

    // Extract pronunciation: prefer top-level `phonetic`, fall back to first non-empty phonetics[].text
    let pronunciation = entry.phonetic
      ?? entry.phonetics?.first(where: { $0.text?.isEmpty == false })?.text
      ?? ""

    // Extract first definition and example across all meanings
    var definitionText = ""
    var exampleText = ""
    outer: for meaning in entry.meanings ?? [] {
      let pos = meaning.partOfSpeech ?? ""
      for def in meaning.definitions ?? [] {
        if definitionText.isEmpty, let d = def.definition, !d.isEmpty {
          definitionText = pos.isEmpty ? d : "(\(pos)) \(d)"
        }
        if exampleText.isEmpty, let e = def.example, !e.isEmpty {
          exampleText = e
        }
        if !definitionText.isEmpty && !exampleText.isEmpty { break outer }
      }
    }

    guard !definitionText.isEmpty else {
      throw DefinitionError.notFound
    }

    return WordDefinition(
      definition: definitionText,
      pronunciation: pronunciation,
      exampleSentence: exampleText
    )
  }

  enum DefinitionError: LocalizedError {
    case apiError
    case parseError
    case notFound

    var errorDescription: String? {
      switch self {
      case .apiError: "Failed to reach the dictionary service."
      case .parseError: "Could not parse the dictionary response."
      case .notFound: "No definition found for this word."
      }
    }
  }
}

// MARK: - dictionaryapi.dev response types

private struct DictionaryEntry: Decodable {
  let word: String?
  let phonetic: String?
  let phonetics: [Phonetic]?
  let meanings: [Meaning]?
}

private struct Phonetic: Decodable {
  let text: String?
}

private struct Meaning: Decodable {
  let partOfSpeech: String?
  let definitions: [Definition]?
}

private struct Definition: Decodable {
  let definition: String?
  let example: String?
}
