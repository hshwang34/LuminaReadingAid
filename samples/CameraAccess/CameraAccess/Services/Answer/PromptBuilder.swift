//
// PromptBuilder.swift
//
// Turns an AnswerPrompt into the exact text handed to the model.
//
// Two properties matter more than wording:
//
//  1. The system prompt is a stored constant, byte-for-byte identical on every turn.
//     That is what allows its KV cache to be computed once per session and reused,
//     removing ~100 tokens of prefill from the latency path of every question.
//
//  2. User prompts stay tiny. The dictionary senses are truncated, the book title is a
//     single line, and nothing resembling page text ever enters a prompt. Prefill is
//     the slowest stage on an A16, and it is paid per question.
//
// Thinking mode needs no defending here: the GBNF grammar forces the first token to be
// `{`, so a <think> block is structurally impossible to emit. The `/no_think` marker
// is kept only to stop the model planning a reasoning chain it will never be allowed
// to write.
//

import Foundation

enum PromptBuilder {

  // MARK: - System prompts

  /// Sense-selection contract. Never changes — see the KV-cache note above.
  static let groundedSystemPrompt = """
    You are Luna, a vocabulary helper for someone reading an English book.
    Reply with STRICT JSON only, exactly these keys in this order:
    {"sense_id": <int>, "short_gloss": "<simple meaning, max 18 words>", \
    "example": "<one short sentence, max 14 words>", "confidence": "high"|"medium"|"low"}
    Rules: pick the numbered sense that best fits the reader's sentence. Rephrase it \
    in plain words a learner understands. sense_id 0 means no listed sense fits. \
    Confidence is how well the sense fits their sentence.
    No text before or after the JSON. /no_think
    """

  /// Conversational follow-up contract.
  static let followUpSystemPrompt = """
    You are Luna, a vocabulary helper for someone reading an English book.
    Answer the reader's question about a word briefly and plainly.
    Reply with STRICT JSON only, exactly these keys in this order:
    {"answer": "<max 30 words>", "confidence": "high"|"medium"|"low"}
    No text before or after the JSON. /no_think
    """

  /// Intent classification, used only when the deterministic router misses.
  static let intentSystemPrompt = """
    Classify the reader's request about a word.
    Reply with STRICT JSON only:
    {"intent": "define"|"example"|"pronounce"|"followup"|"end"|"other", "word": "<word or empty>"}
    No text before or after the JSON. /no_think
    """

  static func systemPrompt(for mode: AnswerPrompt.Mode) -> String {
    switch mode {
    case .define, .exampleSentence: groundedSystemPrompt
    case .followUp: followUpSystemPrompt
    case .intentClassification: intentSystemPrompt
    }
  }

  static func grammar(for mode: AnswerPrompt.Mode) -> String {
    switch mode {
    case .define, .exampleSentence: AnswerSchema.groundedGrammar
    case .followUp: AnswerSchema.followUpGrammar
    case .intentClassification: AnswerSchema.intentGrammar
    }
  }

  static func maxTokens(for mode: AnswerPrompt.Mode) -> Int {
    switch mode {
    case .define, .exampleSentence: AnswerSchema.maxAnswerTokens
    case .followUp: AnswerSchema.maxFollowUpTokens
    case .intentClassification: AnswerSchema.maxIntentTokens
    }
  }

  // MARK: - User prompts

  static func userPrompt(for prompt: AnswerPrompt) -> String {
    switch prompt.mode {
    case .define: definePrompt(prompt)
    case .exampleSentence: examplePrompt(prompt)
    case .followUp: followUpPrompt(prompt)
    case .intentClassification: intentPrompt(prompt)
    }
  }

  private static func definePrompt(_ p: AnswerPrompt) -> String {
    var lines: [String] = []
    lines.append("Word: \"\(p.word ?? p.utterance)\"")
    if let sentence = p.contextSentence {
      lines.append("Reader's sentence: \"\(sentence)\"")
    }
    if !p.candidateSenses.isEmpty {
      lines.append("Senses:")
      // Fewer senses when a sentence is present: the sentence does the
      // disambiguating, and a shorter prompt is a faster first token.
      let limit = p.contextSentence == nil ? 5 : 3
      for sense in p.candidateSenses.prefix(limit) {
        lines.append(sense.promptLine())
      }
    }
    if let book = p.bookTitle {
      lines.append("Book: \"\(book)\"")
    }
    return lines.joined(separator: "\n")
  }

  private static func examplePrompt(_ p: AnswerPrompt) -> String {
    var lines: [String] = []
    lines.append("Word: \"\(p.word ?? p.utterance)\"")
    if !p.candidateSenses.isEmpty {
      lines.append("Senses:")
      for sense in p.candidateSenses.prefix(3) {
        lines.append(sense.promptLine())
      }
    }
    if let target = p.targetSenseID, target > 0 {
      lines.append("Task: write ONE new simple example sentence using sense \(target).")
    } else {
      lines.append("Task: write ONE new simple example sentence using this word.")
    }
    if !p.personalExamples.isEmpty {
      lines.append("Reader's own sentences about similar words:")
      for example in p.personalExamples.prefix(2) {
        lines.append("- \"\(example)\"")
      }
    }
    // sense_id must still be reported so the caller can keep tracking the meaning.
    lines.append("Set short_gloss to the meaning of that sense.")
    return lines.joined(separator: "\n")
  }

  private static func followUpPrompt(_ p: AnswerPrompt) -> String {
    var lines: [String] = []
    if let word = p.word {
      lines.append("The reader was just told about the word \"\(word)\".")
    }
    lines.append("Question: \"\(p.utterance)\"")
    return lines.joined(separator: "\n")
  }

  private static func intentPrompt(_ p: AnswerPrompt) -> String {
    "Utterance: \"\(p.utterance)\""
  }

  // MARK: - ChatML assembly

  /// Qwen3 uses ChatML. Built by hand rather than through a template so the exact
  /// token boundary between the cached system prefix and the per-turn remainder is
  /// known and stable.
  static func systemPrefix(for mode: AnswerPrompt.Mode) -> String {
    "<|im_start|>system\n\(systemPrompt(for: mode))<|im_end|>\n"
  }

  static func turnSuffix(for prompt: AnswerPrompt) -> String {
    var text = ""
    // Follow-up history, oldest first, capped to keep the prompt small.
    if prompt.mode == .followUp {
      for turn in prompt.history.suffix(6) {
        text += "<|im_start|>\(turn.role.rawValue)\n\(turn.content)<|im_end|>\n"
      }
    }
    text += "<|im_start|>user\n\(userPrompt(for: prompt))<|im_end|>\n"
    text += "<|im_start|>assistant\n"
    return text
  }
}
