//
// PromptBuilder.swift
//
// One short system prompt and one turn assembler. That's the entire prompt layer.
//
// The system prompt is byte-identical for the life of the app, which is what lets
// the engine decode it once and keep its KV entries forever — with a single prompt
// there is no mode switch left to invalidate the cache, and prefill per turn is just
// the few dozen tokens of the turn itself.
//
// ChatML framing (<|im_start|>…<|im_end|>) is assembled here because Qwen expects
// it; nothing else in the app needs to know it exists.
//

import Foundation

enum PromptBuilder {

  /// Who Luna is, in as few tokens as the job allows. Every token here is paid for
  /// once per session (prewarmed), but read by the model on every turn.
  static let systemPrompt = """
    You are Luna, a friendly voice assistant for someone reading an English book. \
    They speak to you; your reply is read aloud. Answer in one or two short, plain \
    sentences. When they ask about a word, give its meaning in this context simply, \
    like a good teacher. If a Dictionary line is provided, trust it over your memory. \
    Never use lists, markdown, or symbols — only speakable sentences. /no_think
    """

  // MARK: - ChatML assembly

  /// The constant prefix: system prompt, framed. Decoded once, cached forever.
  static func systemPrefix() -> String {
    "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"
  }

  /// Everything after the cached prefix for one turn: short history, the reader's
  /// words verbatim (plus the optional dictionary line), and the assistant header
  /// the model completes.
  static func turnSuffix(for prompt: AnswerPrompt) -> String {
    var text = ""

    for turn in prompt.history.suffix(4) {
      let role = turn.role == .user ? "user" : "assistant"
      text += "<|im_start|>\(role)\n\(turn.content)<|im_end|>\n"
    }

    var user = ""
    if let line = prompt.dictionaryLine {
      user += line + "\n"
    }
    if let title = prompt.bookTitle, !title.isEmpty {
      user += "(Reading: \(title))\n"
    }
    user += prompt.utterance

    text += "<|im_start|>user\n\(user)<|im_end|>\n"
    text += "<|im_start|>assistant\n"
    return text
  }

  // MARK: - Dictionary line

  /// Folds cached senses into the one line of grounding the prompt carries.
  /// Returns nil when there is nothing cached — the answer never waits on this.
  static func dictionaryLine(word: String, senses: [DictionarySense]) -> String? {
    guard !senses.isEmpty else { return nil }
    let folded = senses.prefix(4)
      .map { $0.promptLine(maxWords: 12) }
      .joined(separator: "; ")
    return "Dictionary: \(word) — \(folded)"
  }
}
