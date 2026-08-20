//
// WordConversationCoordinator.swift
//
// Orchestrates the spoken-word-lookup flow triggered after a word capture:
//
//   1. Generates a concise, context-aware spoken definition via the on-device LLM.
//   2. Speaks it aloud (TTS).
//   3. Opens the microphone with VAD — if the user speaks, captures their question,
//      sends it to the LLM with full context, and speaks the reply.
//   4. Loops as long as the user keeps speaking. Exits when they're silent for
//      the configured no-speech timeout (default 5 s) after a response.
//
// Owns its own SpeechService so it never races the ChatViewModel's instance.
// A new start() call cancels any in-flight conversation and begins fresh.
//

import Foundation

@MainActor
@Observable
final class WordConversationCoordinator {

  enum Phase: Equatable {
    case idle
    case thinking       // LLM is generating a definition or response
    case speaking       // TTS is playing
    case listening      // Mic is open, waiting for user
  }

  private(set) var phase: Phase = .idle

  private let speechService = SpeechService()
  private var currentTask: Task<Void, Never>?
  private var chatHistory: [ChatMessage] = []

  // VAD timing. Matches the user's spec: mic opens 5 s after TTS ends, gives up
  // if nothing is said; silence-after-speech is 1.5 s (natural pause between
  // sentences without cutting mid-thought).
  private let noSpeechTimeout: TimeInterval = 5.0
  private let silenceTimeout: TimeInterval = 1.5

  // MARK: - Public API

  /// Cancels any in-flight conversation and starts a new one for the given word.
  /// Fire-and-forget — all work runs on a background Task.
  func start(word: String, sentenceContext: String, bookTitle: String?) {
    guard !word.isEmpty, !sentenceContext.isEmpty else { return }

    #if DEBUG
    NSLog("""
      [WordConv] ▶ start
        word: "\(word)"
        sentenceContext: "\(sentenceContext)"
        bookTitle: \(bookTitle.map { "\"\($0)\"" } ?? "nil")
      """)
    #endif

    currentTask?.cancel()
    speechService.stopAll()

    currentTask = Task { [weak self] in
      await self?.runConversation(
        word: word,
        sentenceContext: sentenceContext,
        bookTitle: bookTitle
      )
    }
  }

  /// Cancels any in-flight conversation. Safe to call multiple times.
  func stop() {
    currentTask?.cancel()
    currentTask = nil
    speechService.stopAll()
    phase = .idle
  }

  // MARK: - Private

  private func runConversation(word: String, sentenceContext: String, bookTitle: String?) async {
    defer {
      phase = .idle
      speechService.stopAll()
    }

    // 1. Permissions — lazily requested. If denied, bail silently. The rest of
    //    the capture flow (display, dictionary lookup) still works without audio.
    let granted = await speechService.requestPermissions()
    guard granted, !Task.isCancelled else { return }

    // 2. LLM must be loaded. The RootTabView .task already kicks off loading at
    //    app start, so this is usually a no-op, but we guard in case the user
    //    captures a word before the pre-warm completes.
    do {
      try await OnDeviceLLMService.shared.ensureModelLoaded { _ in }
    } catch {
      return
    }
    guard !Task.isCancelled else { return }

    // 3. Generate the concise spoken definition.
    phase = .thinking
    let spoken: String
    do {
      spoken = try await OnDeviceLLMService.shared.generateSpokenDefinition(
        word: word,
        sentenceContext: sentenceContext
      )
    } catch {
      return
    }
    guard !Task.isCancelled, !spoken.isEmpty else { return }

    // 4. Seed chat history with a context-aware system prompt + the spoken
    //    definition as the first assistant turn. Follow-up questions from the
    //    user then feed into the regular chat() pipeline.
    chatHistory = [
      ChatMessage(role: .system, content: Self.systemPrompt(word: word, context: sentenceContext)),
      ChatMessage(role: .assistant, content: spoken),
    ]

    // 5. Speak the definition.
    phase = .speaking
    await speechService.speak(text: spoken)
    guard !Task.isCancelled else { return }

    // 6. Conversation loop: listen → LLM chat → speak → repeat until the user
    //    stops speaking for noSpeechTimeout seconds.
    while !Task.isCancelled {
      phase = .listening
      let transcript: String
      do {
        transcript = try await speechService.listenUntilSilence(
          noSpeechTimeout: noSpeechTimeout,
          silenceTimeout: silenceTimeout
        )
      } catch {
        // Task cancelled or mic error — exit loop.
        break
      }
      guard !Task.isCancelled else { break }

      let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

      #if DEBUG
      NSLog("[WordConv] ◀ STT transcript: \"\(trimmed)\"")
      #endif

      if trimmed.isEmpty {
        // User never spoke during the noSpeechTimeout window — natural exit.
        break
      }

      // 7. Send the user's question to the LLM with full chat history.
      phase = .thinking
      chatHistory.append(ChatMessage(role: .user, content: trimmed))

      #if DEBUG
      NSLog("[WordConv] ▶ chat history sent to LLM (\(chatHistory.count) messages):")
      for (i, msg) in chatHistory.enumerated() {
        NSLog("[WordConv]   [\(i)] \(msg.role.rawValue): \(msg.content)")
      }
      #endif

      let response: String
      do {
        response = try await OnDeviceLLMService.shared.chat(messages: chatHistory)
      } catch {
        break
      }

      #if DEBUG
      NSLog("[WordConv] ◀ chat response: \"\(response)\"")
      #endif
      guard !Task.isCancelled else { break }

      let cleanedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleanedResponse.isEmpty else { break }

      chatHistory.append(ChatMessage(role: .assistant, content: cleanedResponse))

      // 8. Speak the response, then loop back to listening.
      phase = .speaking
      await speechService.speak(text: cleanedResponse)
    }
  }

  private static func systemPrompt(word: String, context: String) -> String {
    """
    You are a friendly reading tutor helping a reader understand vocabulary while \
    they read. The reader just looked up the word "\(word)". It appeared in this sentence:

    "\(context)"

    You already gave them a one-sentence spoken definition. They may now ask brief \
    follow-up questions out loud — about the meaning, usage, synonyms, etymology, or \
    related concepts. Keep every answer very short: 1–2 natural spoken sentences, \
    under 30 words total. No lists, no markdown, no headings. Speak conversationally.
    """
  }
}
