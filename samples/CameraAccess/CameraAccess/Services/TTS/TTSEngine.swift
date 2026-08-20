//
// TTSEngine.swift
//
// The speech-output seam, plus the clause splitter that feeds it.
//
// The engine is queue-shaped rather than call-and-wait on purpose. Answers are
// streamed: the first clause is handed over while the model is still generating the
// rest, so speech begins roughly a second after the reader stops talking instead of
// after generation completes. A `speak(text:) async` shape — which is what the legacy
// SpeechService offers — cannot express that.
//
// Two implementations are planned: AVSpeechSynthesizer first (instant, always
// available, but plainly synthetic) and Kokoro-82M after (natural enough that the
// voice becomes a reason to use the app rather than a thing to tolerate).
//

import Foundation

@MainActor
protocol TTSEngine: AnyObject {

  /// True from the moment the first clause starts sounding until the queue drains.
  var isSpeaking: Bool { get }

  /// Hand over a clause to be spoken after whatever is already queued.
  /// Returns immediately — never blocks the generation loop.
  func enqueue(_ clause: String)

  /// Resolves once everything queued has finished sounding.
  func finishSpeaking() async

  /// Barge-in: drop the queue and stop mid-word.
  func stop()

  /// Pronounce a single word deliberately — slowly, then at natural speed.
  /// Used for the "how do you say X" intent, which never involves the model.
  func speakWordSlowly(_ word: String) async
}

// MARK: - Clause splitting

/// Cuts a token stream into clauses that are worth speaking.
///
/// The tension: emit too eagerly and the voice stutters through fragments; emit too
/// late and the latency win from streaming evaporates. The rule here is to break on
/// sentence terminators always, and on internal punctuation only once enough words
/// have accumulated that the fragment sounds like a phrase rather than a stumble.
struct ClauseSplitter {

  /// Minimum words before a comma or dash is treated as a break point.
  var minimumWordsForSoftBreak: Int = 4
  /// Hard ceiling — if the model produces a long run with no punctuation, break anyway
  /// so speech still starts promptly.
  var maximumWordsPerClause: Int = 18

  private var buffer = ""

  init(minimumWordsForSoftBreak: Int = 4, maximumWordsPerClause: Int = 18) {
    self.minimumWordsForSoftBreak = minimumWordsForSoftBreak
    self.maximumWordsPerClause = maximumWordsPerClause
  }

  private static let hardTerminators: Set<Character> = [".", "!", "?", "\n"]
  private static let softTerminators: Set<Character> = [",", ";", ":", "—", "–"]

  /// Feed text as it arrives; returns any clauses that are now complete.
  mutating func consume(_ text: String) -> [String] {
    var clauses: [String] = []

    for character in text {
      buffer.append(character)

      if Self.hardTerminators.contains(character) {
        // Don't break on a decimal point or an abbreviation like "e.g."
        if character == ".", Self.looksLikeAbbreviation(buffer) { continue }
        appendClause(&clauses)
        continue
      }

      if Self.softTerminators.contains(character), wordCount(buffer) >= minimumWordsForSoftBreak {
        appendClause(&clauses)
        continue
      }

      if character == " ", wordCount(buffer) >= maximumWordsPerClause {
        appendClause(&clauses)
      }
    }

    return clauses
  }

  /// Emit whatever remains once the stream ends.
  /// Applies the same "worth speaking" rule as a mid-stream break, so a trailing
  /// stray "." never becomes its own utterance.
  mutating func flush() -> String? {
    let remaining = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    buffer = ""
    guard remaining.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
    return remaining
  }

  private mutating func appendClause(_ clauses: inout [String]) {
    let clause = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    buffer = ""
    guard !clause.isEmpty else { return }
    // A lone punctuation mark is not worth an utterance.
    guard clause.contains(where: { $0.isLetter || $0.isNumber }) else { return }
    clauses.append(clause)
  }

  private func wordCount(_ s: String) -> Int {
    s.split(whereSeparator: { $0.isWhitespace }).count
  }

  /// Very small guard against breaking inside "e.g.", "i.e.", "Dr." and decimals.
  private static func looksLikeAbbreviation(_ buffer: String) -> Bool {
    let trimmed = buffer.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 2 else { return true }

    let characters = Array(trimmed)
    let beforeDot = characters[characters.count - 2]

    // "3.14" — a digit either side of the dot.
    if beforeDot.isNumber { return true }

    // Single letter before the dot: "e.g", "i.e", initials.
    if characters.count >= 3 {
      let twoBefore = characters[characters.count - 3]
      if beforeDot.isLetter, !twoBefore.isLetter { return true }
    } else if beforeDot.isLetter {
      return true
    }

    return false
  }
}
