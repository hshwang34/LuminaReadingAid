//
// StreamingJSONFieldScanner.swift
//
// Pulls field values out of a JSON object *while it is still streaming*, so the
// first speakable clause can reach TTS long before the model finishes generating.
//
// This is the component that buys most of the latency budget. The model is told to
// emit keys in a fixed order with `short_gloss` early; the moment that value's
// closing quote arrives we can start speaking, while `example` is still decoding.
//
// Approach: rather than a stateful character-by-character parser, each pass tries to
// complete the *next expected field* from a saved cursor. If the value hasn't fully
// arrived, the pass simply returns and the next chunk re-tries from the same cursor.
// Re-scanning is idempotent and the payloads are ~100 tokens, so the cost is nil and
// the correctness argument is much easier to make.
//
// Also defends against a stray `<think>` block: if the model ever ignores the
// no-thinking switch, everything up to `</think>` (and anything before the opening
// brace) is discarded rather than being spoken aloud.
//

import Foundation

struct StreamingJSONFieldScanner {

  /// A key the scanner expects, in emission order.
  struct ExpectedField: Sendable, Equatable {
    let key: String
    /// `true` for string values, `false` for bare values (numbers, literals).
    let isQuoted: Bool

    init(key: String, isQuoted: Bool) {
      self.key = key
      self.isQuoted = isQuoted
    }
  }

  struct Emitted: Equatable {
    let key: String
    let value: String
  }

  private let expected: [ExpectedField]

  /// Everything the model has produced, including any preamble.
  private(set) var rawText = ""
  /// The JSON body, starting at the opening brace.
  private var body: [Character] = []
  private var started = false
  private var cursor = 0
  private var nextIndex = 0

  init(expected: [ExpectedField]) {
    self.expected = expected
  }

  /// All expected fields have been emitted.
  var isComplete: Bool { nextIndex >= expected.count }

  /// Feed the next chunk of model output. Returns any fields that completed.
  mutating func consume(_ chunk: String) -> [Emitted] {
    guard !chunk.isEmpty else { return drain() }
    rawText += chunk

    if started {
      body.append(contentsOf: chunk)
    } else {
      locateBody()
    }

    return drain()
  }

  /// Find the start of the JSON object, skipping any `<think>` block or prose.
  /// Re-runs on every chunk until found, so a tag split across chunks still works.
  private mutating func locateBody() {
    var search = Substring(rawText)

    if let think = search.range(of: "</think>") {
      search = search[think.upperBound...]
    } else if search.range(of: "<think>") != nil {
      // A reasoning block is open. Its contents can contain braces, so committing to
      // a start position now would lock onto the wrong one — wait for it to close.
      return
    }

    guard let brace = search.firstIndex(of: "{") else { return }
    started = true
    body = Array(search[brace...])
    cursor = 0
  }

  private mutating func drain() -> [Emitted] {
    guard started else { return [] }
    var out: [Emitted] = []
    while let field = completeNextField() {
      out.append(field)
    }
    return out
  }

  // MARK: - Field completion

  private mutating func completeNextField() -> Emitted? {
    guard nextIndex < expected.count else { return nil }
    let field = expected[nextIndex]

    let needle = Array("\"\(field.key)\"")
    guard let keyStart = index(of: needle, from: cursor) else { return nil }

    var i = skipWhitespace(from: keyStart + needle.count)
    guard i < body.count, body[i] == ":" else { return nil }

    i = skipWhitespace(from: i + 1)
    guard i < body.count else { return nil }

    return field.isQuoted
      ? completeStringValue(key: field.key, from: i)
      : completeBareValue(key: field.key, from: i)
  }

  private mutating func completeStringValue(key: String, from start: Int) -> Emitted? {
    guard body[start] == "\"" else { return nil }
    var value = ""
    var escaped = false
    var j = start + 1

    while j < body.count {
      let c = body[j]
      if escaped {
        value.append(Self.unescape(c))
        escaped = false
        j += 1
        continue
      }
      if c == "\\" {
        escaped = true
        j += 1
        continue
      }
      if c == "\"" {
        cursor = j + 1
        nextIndex += 1
        return Emitted(key: key, value: value)
      }
      value.append(c)
      j += 1
    }
    return nil  // closing quote hasn't streamed in yet
  }

  private mutating func completeBareValue(key: String, from start: Int) -> Emitted? {
    var value = ""
    var j = start

    while j < body.count {
      let c = body[j]
      if c == "," || c == "}" || c.isWhitespace {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        cursor = j
        nextIndex += 1
        return Emitted(key: key, value: trimmed)
      }
      value.append(c)
      j += 1
    }
    return nil  // no terminator yet — the value may still be growing
  }

  // MARK: - Helpers

  private func skipWhitespace(from index: Int) -> Int {
    var i = index
    while i < body.count, body[i].isWhitespace { i += 1 }
    return i
  }

  private func index(of needle: [Character], from start: Int) -> Int? {
    guard !needle.isEmpty, body.count >= needle.count else { return nil }
    var i = max(0, start)
    let last = body.count - needle.count
    while i <= last {
      var match = true
      for k in 0..<needle.count where body[i + k] != needle[k] {
        match = false
        break
      }
      if match { return i }
      i += 1
    }
    return nil
  }

  private static func unescape(_ c: Character) -> Character {
    switch c {
    case "n": "\n"
    case "t": "\t"
    case "r": "\r"
    case "b": "\u{08}"
    case "f": "\u{0C}"
    default: c  // covers \" \\ \/ and anything unexpected
    }
  }

  // MARK: - Final decode

  /// The JSON object text, with preamble and any trailing prose removed.
  var jsonObjectText: String? {
    guard started, let close = body.lastIndex(of: "}") else { return nil }
    return String(body[0...close])
  }

  /// Decode the completed object. Used for the authoritative result once the stream
  /// ends; the incremental events are for latency, this is for correctness.
  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    guard let text = jsonObjectText, let data = text.data(using: .utf8) else {
      throw AnswerEngineError.invalidOutput
    }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw AnswerEngineError.invalidOutput
    }
  }
}
