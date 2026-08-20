//
// OnDeviceLLMService.swift
//
// On-device LLM inference using MLX Swift + Qwen2.5-1.5B-Instruct-4bit.
// Provides contextual word definitions without any server dependency.
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

struct ChatMessage: Sendable {
  enum Role: String, Sendable { case system, user, assistant }
  let role: Role
  let content: String
}

struct CoverFields: Sendable {
  let title: String
  let author: String
  /// Raw Qwen output before parsing, for debug display.
  let rawOutput: String
}

actor OnDeviceLLMService {

  static let shared = OnDeviceLLMService()

  enum ModelState: Sendable {
    case idle
    case downloading(progress: Double)
    case loading
    case ready
    case error(String)
  }

  private(set) var state: ModelState = .idle
  private var modelContainer: ModelContainer?

  var isReady: Bool {
    if case .ready = state { return true }
    return false
  }

  // MARK: - Model Lifecycle

  func ensureModelLoaded(onProgress: @Sendable @escaping (Double) -> Void) async throws {
    if isReady { return }

    GPU.set(cacheLimit: 20 * 1024 * 1024)

    state = .downloading(progress: 0)

    let config = ModelConfiguration(id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit")

    let container = try await LLMModelFactory.shared.loadContainer(
      configuration: config
    ) { progress in
      Task { @MainActor in onProgress(progress.fractionCompleted) }
    }

    state = .loading
    self.modelContainer = container

    // Warm up Metal shaders with a dummy prompt
    _ = try await runInference(prompt: "Hi", maxTokens: 5, temperature: 0.0)

    state = .ready
  }

  // MARK: - Quiz Distractor Generation

  func generateQuizDistractors(word: String, correctDefinition: String) async throws -> [String] {
    guard modelContainer != nil else {
      throw LLMError.modelNotLoaded
    }

    let systemPrompt = """
      You are a vocabulary quiz generator. Given a word and its correct definition, \
      generate exactly 3 plausible but INCORRECT definitions that could trick a learner. \
      Each distractor should be a similar length to the correct definition and sound \
      believable. They should be wrong but not absurdly so.

      Respond in exactly this format:
      1. first wrong definition
      2. second wrong definition
      3. third wrong definition
      """

    let userPrompt = """
      Word: "\(word)"
      Correct definition: "\(correctDefinition)"
      """

    let fullPrompt = """
      <|im_start|>system
      \(systemPrompt)<|im_end|>
      <|im_start|>user
      \(userPrompt)<|im_end|>
      <|im_start|>assistant
      """

    let output = try await runInference(prompt: fullPrompt, maxTokens: 150, temperature: 0.7)
    return parseDistractors(output)
  }

  private func parseDistractors(_ text: String) -> [String] {
    var distractors: [String] = []
    let lines = text.components(separatedBy: "\n")
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      // Match lines starting with "1.", "2.", "3."
      if let range = trimmed.range(of: #"^\d+\.\s*"#, options: .regularExpression) {
        let content = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if !content.isEmpty {
          distractors.append(content)
        }
      }
    }
    return distractors
  }

  func generateQuizDistractorWords(correctWord: String) async throws -> [String] {
    guard modelContainer != nil else {
      throw LLMError.modelNotLoaded
    }

    let systemPrompt = """
      You are a vocabulary quiz generator. Given a word, generate exactly 3 other \
      real English words that a learner might confuse with it. They should be similar \
      in length, frequency, or sound — plausible wrong answers.

      Respond in exactly this format:
      1. first word
      2. second word
      3. third word
      """

    let fullPrompt = """
      <|im_start|>system
      \(systemPrompt)<|im_end|>
      <|im_start|>user
      Word: "\(correctWord)"<|im_end|>
      <|im_start|>assistant
      """

    let output = try await runInference(prompt: fullPrompt, maxTokens: 60, temperature: 0.7)
    return parseDistractors(output)
  }

  // MARK: - Chat

  func chat(messages: [ChatMessage]) async throws -> String {
    guard modelContainer != nil else {
      throw LLMError.modelNotLoaded
    }

    var prompt = ""
    for message in messages {
      prompt += "<|im_start|>\(message.role.rawValue)\n\(message.content)<|im_end|>\n"
    }
    prompt += "<|im_start|>assistant\n"

    return try await runInference(prompt: prompt, maxTokens: 200, temperature: 0.6)
  }

  // MARK: - Definition Generation

  func generateDefinition(word: String, bookTitle: String?, context: String? = nil) async throws -> WordDefinition {
    guard let container = modelContainer else {
      throw LLMError.modelNotLoaded
    }

    let systemPrompt = """
      You are a concise English dictionary. Given a word and optionally the book \
      it appears in and surrounding text context, provide a brief definition \
      (one sentence with part of speech), pronunciation in IPA, and an example sentence. \
      Use the context to disambiguate the meaning if multiple definitions exist.

      Respond in exactly this format:
      DEFINITION: (part of speech) definition here
      PRONUNCIATION: /IPA here/
      EXAMPLE: Example sentence here.
      """

    let bookContext = bookTitle ?? "unknown"
    var userPrompt = """
      Word: "\(word)"
      Book: "\(bookContext)"
      """
    if let context, !context.isEmpty {
      userPrompt += "\nContext: \"\(context)\""
    }

    let fullPrompt = """
      <|im_start|>system
      \(systemPrompt)<|im_end|>
      <|im_start|>user
      \(userPrompt)<|im_end|>
      <|im_start|>assistant
      """

    let output = try await runInference(prompt: fullPrompt, maxTokens: 120, temperature: 0.0)
    return parseResponse(output)
  }

  // MARK: - Book Cover Field Extraction

  /// Splits raw OCR lines from a book cover into a clean title + author pair.
  /// Uses chain-of-thought prompting to encourage the small Qwen model to
  /// reason about which lines are names vs descriptive phrases before
  /// committing to an answer. Returns empty strings for fields it can't
  /// determine — callers must handle that.
  func extractCoverFields(ocrLines: [String]) async throws -> CoverFields {
    guard modelContainer != nil else {
      throw LLMError.modelNotLoaded
    }

    #if DEBUG
    NSLog("[CoverLLM] ▶ input OCR lines (%d):", ocrLines.count)
    for line in ocrLines {
      NSLog("[CoverLLM]   - \"%@\"", line)
    }
    #endif

    // Chain-of-thought prompt with explicit heuristics and 3 diverse few-shot
    // examples. Small quantized models (Qwen 1.5B @ Q4) are known to fail
    // zero-shot classification even with demonstrations, but improve
    // substantially when forced to reason step-by-step before answering.
    let systemPrompt = """
      You are a book-cover parser. Your job: given OCR'd lines from a book cover, \
      classify each line and identify the TITLE and primary AUTHOR.

      HEURISTICS FOR CLASSIFICATION:
      • TITLE — a descriptive phrase of 2+ words describing the book's subject, \
      concept, or story. Usually a noun phrase like "The Shining", "Sapiens", \
      "Solving Product Design Exercises".
      • AUTHOR — a person's name: almost always 2–3 capitalized words matching \
      "First Last" or "First Middle Last". Examples: "Stephen King", \
      "J. R. R. Tolkien", "Artiom Dashinsky".
      • NOISE — ignore award/blurb tags ("NEW YORK TIMES BESTSELLER", \
      "WINNER OF THE BOOKER PRIZE"), format labels ("A NOVEL", "STORIES"), \
      publisher imprints ("PENGUIN CLASSICS"), series identifiers \
      ("BOOK ONE OF"), subtitles, and marketing copy.

      CRITICAL: The title and author are DIFFERENT lines. Never output the same \
      text for both. A person's name is never a book's title.

      REASONING FORMAT: Think step by step. First classify each OCR line. Then \
      pick the best title and author from your classifications.

      OUTPUT FORMAT (exact):
      REASONING: <brief per-line classification>
      TITLE: <the book title>
      AUTHOR: <the primary author>

      Here are three examples:

      Example 1:
      OCR lines:
      - NEW YORK TIMES BESTSELLER
      - STEPHEN KING
      - THE SHINING
      - A NOVEL

      REASONING: "NEW YORK TIMES BESTSELLER" is an award blurb (noise); \
      "STEPHEN KING" is two capitalized words — a person's name (author); \
      "THE SHINING" is a descriptive phrase (title); "A NOVEL" is a format \
      label (noise).
      TITLE: The Shining
      AUTHOR: Stephen King

      Example 2:
      OCR lines:
      - Solving Product Design Exercises
      - Questions & Answers used by leading design employers
      - Artiom Dashinsky

      REASONING: "Solving Product Design Exercises" is a descriptive phrase \
      (title); "Questions & Answers used by leading design employers" is a \
      subtitle (noise for our purposes); "Artiom Dashinsky" is two capitalized \
      words looking like a name (author).
      TITLE: Solving Product Design Exercises
      AUTHOR: Artiom Dashinsky

      Example 3:
      OCR lines:
      - The Hobbit
      - or There and Back Again
      - J. R. R. Tolkien
      - Fiftieth Anniversary Edition

      REASONING: "The Hobbit" is the primary title; "or There and Back Again" \
      is the subtitle (noise); "J. R. R. Tolkien" is a name with initials \
      (author); "Fiftieth Anniversary Edition" is noise.
      TITLE: The Hobbit
      AUTHOR: J. R. R. Tolkien
      """

    let joinedLines = ocrLines
      .map { "- \($0)" }
      .joined(separator: "\n")
    let userPrompt = """
      OCR lines:
      \(joinedLines)

      REASONING:
      """

    let fullPrompt = """
      <|im_start|>system
      \(systemPrompt)<|im_end|>
      <|im_start|>user
      \(userPrompt)<|im_end|>
      <|im_start|>assistant
      """

    let output = try await runInference(prompt: fullPrompt, maxTokens: 220, temperature: 0.0)
    #if DEBUG
    NSLog("[CoverLLM] ◀ raw output: \"%@\"", output)
    #endif
    return validateAndParse(output)
  }

  /// Parse the model's output and apply sanity checks. Returns empty fields
  /// when Qwen produces the known failure mode (title == author) or when it
  /// echoes prompt boilerplate — that way downstream falls through cleanly
  /// to the Open Library line-by-line fallback.
  private func validateAndParse(_ text: String) -> CoverFields {
    var title = ""
    var author = ""
    for line in text.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("TITLE:") {
        title = String(trimmed.dropFirst("TITLE:".count)).trimmingCharacters(in: .whitespaces)
      } else if trimmed.hasPrefix("AUTHOR:") {
        author = String(trimmed.dropFirst("AUTHOR:".count)).trimmingCharacters(in: .whitespaces)
      }
    }

    // Sanity check 1: both fields identical and non-empty → Qwen collapsed.
    if !title.isEmpty, title == author {
      #if DEBUG
      NSLog("[CoverLLM] ⚠︎ sanity check failed: title == author — dropping both")
      #endif
      return CoverFields(title: "", author: "", rawOutput: text)
    }

    // Sanity check 2: Qwen echoed boilerplate — detect a few signature strings.
    let boilerplate: Set<String> = [
      "the book title", "the primary author", "<the book title>",
      "<the primary author>", "a descriptive phrase", "a person's name"
    ]
    let titleLower = title.lowercased()
    let authorLower = author.lowercased()
    if boilerplate.contains(titleLower) { title = "" }
    if boilerplate.contains(authorLower) { author = "" }

    return CoverFields(title: title, author: author, rawOutput: text)
  }

  // MARK: - Spoken Definition (TTS-optimized)

  /// Generates a single concise sentence explaining a word in the context of the
  /// sentence it was used in, optimized for speech synthesis. No IPA, no
  /// part-of-speech labels, no markdown — just one natural-sounding sentence.
  /// This is separate from generateDefinition() which returns a structured
  /// WordDefinition for display storage.
  func generateSpokenDefinition(word: String, sentenceContext: String) async throws -> String {
    guard modelContainer != nil else {
      throw LLMError.modelNotLoaded
    }

    let systemPrompt = """
      You are helping a reader understand a vocabulary word they just looked up \
      while reading. Given the word and the sentence it appears in, explain the \
      meaning of the word as used in that specific sentence.

      Strict format:
      - ALWAYS start your response with the exact word itself, followed by the word "means", \
        then the contextual definition. The word must be the very first word of your response.
      - Respond with exactly ONE natural sentence.
      - Maximum 25 words total.
      - No IPA pronunciation. No part-of-speech labels. No quotation marks around the word.
      - No lists, no markdown, no prefixes like "Definition:" or "Answer:".
      - Speak conversationally, as if explaining out loud.

      Examples of the required format:
      - Word: "prodigious" → "Prodigious means extraordinarily large — here describing how enormous her love of reading was."
      - Word: "meander" → "Meander means to wander slowly without a clear path, like the river winding through the valley."
      - Word: "ephemeral" → "Ephemeral means lasting only a very short time, capturing how briefly the moment existed."
      """

    let userPrompt = """
      Word: \(word)
      Sentence: \(sentenceContext)
      """

    let fullPrompt = """
      <|im_start|>system
      \(systemPrompt)<|im_end|>
      <|im_start|>user
      \(userPrompt)<|im_end|>
      <|im_start|>assistant
      """

    #if DEBUG
    NSLog("""
      [SpokenDef] ▶ inputs
        word: "\(word)"
        sentence: "\(sentenceContext)"
      [SpokenDef] ▶ full prompt sent to model:
      ---BEGIN PROMPT---
      \(fullPrompt)
      ---END PROMPT---
      """)
    #endif

    let output = try await runInference(prompt: fullPrompt, maxTokens: 80, temperature: 0.3)

    #if DEBUG
    NSLog("[SpokenDef] ◀ raw model output: \"\(output)\"")
    #endif

    // Strip common model artifacts — leading "Definition:" prefixes, wrapping quotes,
    // trailing explanatory text after the first sentence.
    let cleaned = cleanSpokenOutput(output)

    #if DEBUG
    NSLog("[SpokenDef] ◀ cleaned (sent to TTS): \"\(cleaned)\"")
    #endif

    return cleaned
  }

  private func cleanSpokenOutput(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    // Strip leading "Definition:" / "Answer:" / "Meaning:" prefixes.
    let prefixes = ["definition:", "meaning:", "answer:", "explanation:"]
    let lower = text.lowercased()
    for prefix in prefixes where lower.hasPrefix(prefix) {
      text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
      break
    }

    // Strip wrapping quotes.
    let quoteChars: Set<Character> = ["\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}"]
    while let first = text.first, quoteChars.contains(first) { text.removeFirst() }
    while let last = text.last, quoteChars.contains(last) { text.removeLast() }

    // Keep only the first sentence to enforce brevity if the model over-generated.
    if let terminator = text.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
      let endIndex = text.index(after: terminator)
      text = String(text[..<endIndex])
    }

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Private

  private func runInference(prompt: String, maxTokens: Int, temperature: Float = 0.0) async throws -> String {
    guard let container = modelContainer else {
      throw LLMError.modelNotLoaded
    }

    var output = ""

    _ = try await container.perform { context in
      let input = UserInput(prompt: prompt)
      let prepared = try await context.processor.prepare(input: input)

      return try MLXLMCommon.generate(
        input: prepared,
        parameters: GenerateParameters(temperature: temperature),
        context: context
      ) { tokens in
        let text = context.tokenizer.decode(tokens: tokens)
        output = text
        return tokens.count >= maxTokens ? .stop : .more
      }
    }

    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func parseResponse(_ text: String) -> WordDefinition {
    var definition = ""
    var pronunciation = ""
    var example = ""

    let lines = text.components(separatedBy: "\n")
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("DEFINITION:") {
        definition = String(trimmed.dropFirst("DEFINITION:".count)).trimmingCharacters(in: .whitespaces)
      } else if trimmed.hasPrefix("PRONUNCIATION:") {
        pronunciation = String(trimmed.dropFirst("PRONUNCIATION:".count)).trimmingCharacters(in: .whitespaces)
      } else if trimmed.hasPrefix("EXAMPLE:") {
        example = String(trimmed.dropFirst("EXAMPLE:".count)).trimmingCharacters(in: .whitespaces)
      }
    }

    // Fallback: if structured parsing failed, use entire text as definition
    if definition.isEmpty {
      definition = text
    }

    return WordDefinition(
      definition: definition,
      pronunciation: pronunciation,
      exampleSentence: example
    )
  }

  enum LLMError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
      switch self {
      case .modelNotLoaded: "AI model is not loaded. Please try again."
      }
    }
  }
}
