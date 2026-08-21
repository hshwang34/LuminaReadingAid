//
// LlamaAnswerEngine.swift
//
// llama.cpp, doing one thing: turning the reader's words into a short spoken answer.
//
// Three properties are load-bearing:
//
//  1. ONE PROMPT. There is a single system prompt and no modes, so its KV entries are
//     decoded once — at prepare(), before anyone has asked anything — and reused for
//     every turn of the session. Per-turn prefill is just the turn itself, a few
//     dozen tokens. The previous design's mode switching re-decoded hundreds of
//     tokens of static text on every question and was most of a six-second turn.
//
//  2. CPU ONLY. iOS refuses GPU work from a backgrounded app, and the locked phone is
//     the scenario this app exists for. Verified on device: Metal inference dies with
//     kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted the moment the
//     screen locks, and the failure wedges the backend. See `gpuLayers`.
//
//  3. MMAP. Weights are clean file-backed pages the OS can evict and re-fault, which
//     is what lets a session sit backgrounded for an hour without becoming the first
//     Jetsam casualty.
//
// The type is an actor because a llama context is not thread-safe. The generation
// loop yields between tokens so cancellation — a new question, the session ending —
// can actually land.
//

import Foundation
import LlamaSwift
import UIKit
import os

actor LlamaAnswerEngine: AnswerEngine {

  static let shared = LlamaAnswerEngine()

  // MARK: - State

  private var model: OpaquePointer?
  private var context: OpaquePointer?
  private var vocab: OpaquePointer?

  /// Tokens of system prompt resident in the KV cache. Decoded once per model load;
  /// with a single prompt there is nothing left that can invalidate it.
  private var cachedPrefixTokens: Int32 = 0

  private var state: AnswerEngineReadiness = .notReady

  /// Bumped to supersede an in-flight generation.
  private var generationID: UInt64 = 0

  /// Bytes of a UTF-8 sequence split across tokens, held until it completes.
  private var pendingBytes: [UInt8] = []

  /// Consecutive fatal decode failures; see recoverFromDecodeFailure().
  private var consecutiveDecodeFailures = 0

  private static var backendInitialized = false

  private let contextTokens: UInt32 = 2048
  private let batchTokens: UInt32 = 512

  /// Decode threads. An A16 has two performance and four efficiency cores; spreading
  /// a decode across all six makes every step wait on the slowest thread.
  private let threads: Int32 = 4
  /// Prefill parallelises much better than decode, so it may use the efficiency
  /// cores profitably.
  private let batchThreads: Int32 = 6

  // MARK: - Compute placement

  /// GPU layers to offload. **0 — CPU only — is the shipping configuration**, because
  /// Metal cannot execute while the app is backgrounded and a locked phone must
  /// answer exactly like an unlocked one. The DEBUG override exists to measure the
  /// difference on device, nothing more.
  static var gpuLayers: Int32 {
    get {
      #if DEBUG
      let stored = UserDefaults.standard.object(forKey: gpuLayersKey) as? Int
      return Int32(stored ?? 0)
      #else
      return 0
      #endif
    }
    set {
      #if DEBUG
      UserDefaults.standard.set(Int(newValue), forKey: gpuLayersKey)
      #endif
    }
  }

  private static let gpuLayersKey = "luna.llama.gpuLayers"

  /// Change the offload setting and reload so it takes effect. Debug harness only.
  func setGPULayers(_ layers: Int32) async throws {
    guard Self.gpuLayers != layers else { return }
    Self.gpuLayers = layers
    guard LlamaModelStore.shared.isModelPresent else { return }
    state = .loading
    do {
      try loadModel(at: LlamaModelStore.shared.modelFileURL)
      try prewarmSystemPrefix()
      state = .ready
    } catch {
      state = .failed(error.localizedDescription)
      throw error
    }
  }

  // MARK: - AnswerEngine

  var readiness: AnswerEngineReadiness { state }

  func prepare(onProgress: @Sendable @escaping (AnswerEngineReadiness) -> Void) async throws {
    if case .ready = state {
      onProgress(state)
      return
    }

    do {
      let store = LlamaModelStore.shared
      if !store.isModelPresent {
        state = .downloading(progress: 0)
        onProgress(state)
      }

      let url = try await store.ensureModel { fraction in
        onProgress(.downloading(progress: fraction))
      }

      state = .loading
      onProgress(state)
      let loadStarted = Date()
      try loadModel(at: url)

      // Decode the system prompt now, while nobody is waiting for an answer. This is
      // what makes the first question of a session cost the same as the fifth.
      try prewarmSystemPrefix()
      Log.llm.info("model ready in \(Int(Date().timeIntervalSince(loadStarted) * 1000), privacy: .public) ms — \(Self.gpuLayers, privacy: .public) GPU layers, prefix prewarmed (\(self.cachedPrefixTokens, privacy: .public) tokens)")

      state = .ready
      onProgress(state)
    } catch {
      let message = error.localizedDescription
      state = .failed(message)
      onProgress(state)
      throw AnswerEngineError.modelLoadFailed(message)
    }
  }

  nonisolated func generate(_ prompt: AnswerPrompt) -> AsyncThrowingStream<AnswerStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await self.run(prompt, into: continuation)
          continuation.finish()
        } catch {
          continuation.finish(throwing: await self.explain(error))
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func cancelCurrent() {
    generationID &+= 1
  }

  // MARK: - Model lifecycle

  private func loadModel(at url: URL) throws {
    if !Self.backendInitialized {
      llama_backend_init()
      Self.backendInitialized = true
    }

    unloadLocked()

    var modelParams = llama_model_default_params()
    modelParams.load_mode = LLAMA_LOAD_MODE_MMAP
    modelParams.n_gpu_layers = Self.gpuLayers

    guard let loaded = llama_model_load_from_file(url.path, modelParams) else {
      throw AnswerEngineError.modelLoadFailed("could not open \(url.lastPathComponent)")
    }
    model = loaded
    vocab = llama_model_get_vocab(loaded)

    do {
      try makeContext()
    } catch {
      llama_model_free(loaded)
      model = nil
      vocab = nil
      throw error
    }
  }

  /// Creates the inference context, replacing any existing one.
  ///
  /// Separate from model loading because the compute backend lives with the context,
  /// not the model — this is also the recovery path after a backend failure, and it
  /// is far cheaper than re-reading a gigabyte of weights.
  private func makeContext() throws {
    guard let model else { throw AnswerEngineError.modelUnavailable }

    if let context { llama_free(context) }
    context = nil
    cachedPrefixTokens = 0

    var ctxParams = llama_context_default_params()
    ctxParams.n_ctx = contextTokens
    ctxParams.n_batch = batchTokens
    ctxParams.n_threads = threads
    ctxParams.n_threads_batch = batchThreads

    guard let ctx = llama_init_from_model(model, ctxParams) else {
      throw AnswerEngineError.modelLoadFailed("could not create context")
    }
    context = ctx
  }

  /// Decode the constant system prefix into the KV cache so no turn ever pays for it.
  private func prewarmSystemPrefix() throws {
    guard context != nil else { throw AnswerEngineError.modelUnavailable }
    let prefix = tokenize(PromptBuilder.systemPrefix(), addSpecial: true)
    try decode(prefix)
    cachedPrefixTokens = Int32(prefix.count)
  }

  /// Frees the model. Called on memory pressure while idle; the next question pays
  /// the reload.
  func unload() {
    unloadLocked()
    state = .notReady
  }

  private func unloadLocked() {
    if let context { llama_free(context) }
    if let model { llama_model_free(model) }
    context = nil
    model = nil
    vocab = nil
    cachedPrefixTokens = 0
  }

  // MARK: - Generation

  private func run(
    _ prompt: AnswerPrompt,
    into continuation: AsyncThrowingStream<AnswerStreamEvent, Error>.Continuation
  ) async throws {

    guard case .ready = state, let context, let vocab else {
      throw AnswerEngineError.modelUnavailable
    }

    generationID &+= 1
    let myID = generationID
    pendingBytes.removeAll(keepingCapacity: true)

    let started = Date()
    Log.llm.info("generation started — \"\(prompt.utterance, privacy: .public)\"")

    // A raw completion (quiz distractors, enrichment) may have displaced the
    // prewarmed prefix; restore it before this turn rather than during prepare().
    if cachedPrefixTokens == 0 {
      try prewarmSystemPrefix()
      Log.llm.info("system prefix re-warmed after raw completion")
    }

    // Keep the prewarmed system prefix; drop whatever the previous turn left.
    llama_memory_seq_rm(llama_get_memory(context), 0, cachedPrefixTokens, -1)

    let turn = tokenize(PromptBuilder.turnSuffix(for: prompt), addSpecial: false)
    guard cachedPrefixTokens + Int32(turn.count) + Int32(AnswerSampling.maxTokens)
            < Int32(contextTokens) else {
      throw AnswerEngineError.generationFailed("prompt too long for context")
    }
    try decode(turn)
    Log.llm.info("prefill done — \(turn.count, privacy: .public) turn tokens in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms (prefix reused: \(self.cachedPrefixTokens, privacy: .public))")

    // ── Sampler: Qwen's recommended prose settings ─────────────────────────
    let chainParams = llama_sampler_chain_default_params()
    guard let chain = llama_sampler_chain_init(chainParams) else {
      throw AnswerEngineError.generationFailed("sampler chain")
    }
    defer { llama_sampler_free(chain) }

    llama_sampler_chain_add(chain, llama_sampler_init_top_k(AnswerSampling.topK))
    llama_sampler_chain_add(chain, llama_sampler_init_top_p(AnswerSampling.topP, 1))
    llama_sampler_chain_add(chain, llama_sampler_init_temp(AnswerSampling.temperature))
    llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: .min ... .max)))

    // ── Decode loop: plain text, straight through to speech ─────────────────
    var stripper = ThinkStripper()
    var splitter = ClauseSplitter()
    var answer = ""
    var produced = 0

    while produced < AnswerSampling.maxTokens {
      guard myID == generationID else { throw AnswerEngineError.cancelled }
      try Task.checkCancellation()

      let token = llama_sampler_sample(chain, context, -1)
      if llama_vocab_is_eog(vocab, token) { break }

      let piece = decodePiece(token)
      let speakableText = stripper.consume(piece)
      if !speakableText.isEmpty {
        answer += speakableText
        for clause in splitter.consume(speakableText) {
          continuation.yield(.speakable(clause))
        }
      }

      try decode([token])
      produced += 1
      await Task.yield()
    }

    if let tail = splitter.flush() {
      continuation.yield(.speakable(tail))
    }

    let seconds = Date().timeIntervalSince(started)
    Log.llm.info("generation done — \(produced, privacy: .public) tokens in \(Int(seconds * 1000), privacy: .public) ms (\(String(format: "%.1f", Double(produced) / max(seconds, 0.001)), privacy: .public) tok/s)")

    continuation.yield(.final(answer.trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  // MARK: - Raw completion

  /// One-shot text completion for the app's utility work: quiz distractors, word
  /// enrichment, cover-field extraction. This is what let the MLX runtime retire —
  /// those features now share the voice session's model instead of holding a second
  /// ~1 GB runtime resident alongside it.
  ///
  /// Uses its own system prompt, so it evicts the voice session's prewarmed KV
  /// prefix; the next voice turn re-warms lazily (~half a second). Utility calls are
  /// rare and mostly happen outside sessions, so that trade is taken here rather
  /// than on the answer path.
  /// - Parameter chatML: a fully assembled ChatML prompt ending in the assistant
  ///   header. Callers own the framing because one of them (conversation chat)
  ///   carries multi-turn history that a system/user pair cannot express.
  func complete(
    chatML: String,
    maxTokens: Int,
    temperature: Float = 0.0
  ) async throws -> String {
    guard case .ready = state, let context, let vocab else {
      throw AnswerEngineError.modelUnavailable
    }

    generationID &+= 1
    let myID = generationID
    pendingBytes.removeAll(keepingCapacity: true)

    // This prompt replaces everything, including the voice prefix.
    llama_memory_seq_rm(llama_get_memory(context), 0, 0, -1)
    cachedPrefixTokens = 0

    let tokens = tokenize(chatML, addSpecial: true)
    guard Int32(tokens.count + maxTokens) < Int32(contextTokens) else {
      throw AnswerEngineError.generationFailed("prompt too long for context")
    }
    try decode(tokens)

    let chainParams = llama_sampler_chain_default_params()
    guard let chain = llama_sampler_chain_init(chainParams) else {
      throw AnswerEngineError.generationFailed("sampler chain")
    }
    defer { llama_sampler_free(chain) }

    if temperature <= 0 {
      // Extraction and structured utility work wants determinism.
      llama_sampler_chain_add(chain, llama_sampler_init_greedy())
    } else {
      llama_sampler_chain_add(chain, llama_sampler_init_top_k(AnswerSampling.topK))
      llama_sampler_chain_add(chain, llama_sampler_init_top_p(AnswerSampling.topP, 1))
      llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))
      llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: .min ... .max)))
    }

    var stripper = ThinkStripper()
    var output = ""
    var produced = 0

    while produced < maxTokens {
      guard myID == generationID else { throw AnswerEngineError.cancelled }
      try Task.checkCancellation()

      let token = llama_sampler_sample(chain, context, -1)
      if llama_vocab_is_eog(vocab, token) { break }

      output += stripper.consume(decodePiece(token))

      try decode([token])
      produced += 1
      await Task.yield()
    }

    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Failure recovery

  /// Put the context back into a usable state after a fatal decode.
  ///
  /// ggml states the requirement outright: "backend is in error state from a previous
  /// command buffer failure - recreate the backend to recover". The backend lives
  /// with the context, so the context is rebuilt (and the prefix re-warmed); without
  /// this, one failed decode ends every answer until the app relaunches.
  private func recoverFromDecodeFailure() {
    consecutiveDecodeFailures += 1
    pendingBytes.removeAll(keepingCapacity: true)

    do {
      try makeContext()
      try prewarmSystemPrefix()
    } catch {
      unloadLocked()
      state = .notReady
      consecutiveDecodeFailures = 0
      return
    }

    // A fresh context that fails again is not a transient fault; drop the model so
    // the next question pays a reload rather than failing a third time.
    if consecutiveDecodeFailures >= 3 {
      unloadLocked()
      state = .notReady
      consecutiveDecodeFailures = 0
    }
  }

  /// Names the one iOS-specific cause of a decode failure worth explaining.
  private func explain(_ error: Error) async -> Error {
    guard case AnswerEngineError.generationFailed(let detail) = error,
          detail.contains("llama_decode") else { return error }

    let isForeground = await MainActor.run {
      UIApplication.shared.applicationState == .active
    }
    guard !isForeground, Self.gpuLayers > 0 else { return error }

    return AnswerEngineError.generationFailed(
      "iOS does not permit GPU work from a backgrounded app, so Metal inference cannot "
      + "run while the phone is locked (\(detail)). Set the model to CPU only to answer "
      + "in this state."
    )
  }

  // MARK: - llama.cpp primitives

  private func tokenize(_ text: String, addSpecial: Bool) -> [llama_token] {
    guard let vocab else { return [] }
    let cString = Array(text.utf8CString)
    let textLength = Int32(cString.count - 1)  // drop the NUL

    var tokens = [llama_token](repeating: 0, count: Int(textLength) + 8)
    var count = llama_tokenize(
      vocab, cString, textLength, &tokens, Int32(tokens.count), addSpecial, true
    )
    if count < 0 {
      tokens = [llama_token](repeating: 0, count: Int(-count))
      count = llama_tokenize(
        vocab, cString, textLength, &tokens, Int32(tokens.count), addSpecial, true
      )
    }
    guard count > 0 else { return [] }
    return Array(tokens.prefix(Int(count)))
  }

  /// Decodes in n_batch-sized chunks so a long prompt can never overflow the batch.
  private func decode(_ tokens: [llama_token]) throws {
    guard let context, !tokens.isEmpty else { return }
    var offset = 0
    while offset < tokens.count {
      let end = min(offset + Int(batchTokens), tokens.count)
      var chunk = Array(tokens[offset..<end])
      let status: Int32 = chunk.withUnsafeMutableBufferPointer { buffer in
        let batch = llama_batch_get_one(buffer.baseAddress, Int32(buffer.count))
        return llama_decode(context, batch)
      }
      guard status == 0 else {
        recoverFromDecodeFailure()
        throw AnswerEngineError.generationFailed("llama_decode returned \(status)")
      }
      offset = end
    }
    consecutiveDecodeFailures = 0
  }

  /// Converts a token to text, buffering bytes that end mid-UTF8-sequence.
  private func decodePiece(_ token: llama_token) -> String {
    guard let vocab else { return "" }

    var buffer = [CChar](repeating: 0, count: 64)
    var written = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
    if written < 0 {
      buffer = [CChar](repeating: 0, count: Int(-written))
      written = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
    }
    guard written > 0 else { return "" }

    pendingBytes.append(contentsOf: buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) })

    guard let text = String(bytes: pendingBytes, encoding: .utf8) else {
      return ""  // incomplete sequence — wait for the next token's bytes
    }
    pendingBytes.removeAll(keepingCapacity: true)
    return text
  }
}

// MARK: - Think stripper

/// Removes a `<think>…</think>` span from a token stream before it can be spoken.
///
/// The prompt disables thinking, but a guardrail that depends on a model always
/// following instructions is not a guardrail. This is the whole defence: nothing
/// between the tags — and no fragment of the tags themselves — ever reaches the
/// clause splitter.
struct ThinkStripper {

  private enum State { case scanning, inThink }
  private var state: State = .scanning
  /// Holds a suffix that might be the start of a tag split across tokens.
  private var held = ""

  private static let open = "<think>"
  private static let close = "</think>"

  /// Feed raw model text; returns only what is safe to speak.
  mutating func consume(_ chunk: String) -> String {
    var buffer = held + chunk
    held = ""
    var out = ""

    while !buffer.isEmpty {
      switch state {
      case .scanning:
        if let range = buffer.range(of: Self.open) {
          out += buffer[..<range.lowerBound]
          buffer = String(buffer[range.upperBound...])
          state = .inThink
        } else if let partial = Self.partialSuffix(of: buffer, matching: Self.open) {
          out += buffer.dropLast(partial.count)
          held = partial
          buffer = ""
        } else {
          out += buffer
          buffer = ""
        }

      case .inThink:
        if let range = buffer.range(of: Self.close) {
          buffer = String(buffer[range.upperBound...])
          state = .scanning
        } else if let partial = Self.partialSuffix(of: buffer, matching: Self.close) {
          held = partial
          buffer = ""
        } else {
          buffer = ""  // discard reasoning text
        }
      }
    }
    return out
  }

  /// The longest suffix of `text` that is a proper prefix of `tag`, or nil.
  private static func partialSuffix(of text: String, matching tag: String) -> String? {
    let maxLength = min(text.count, tag.count - 1)
    guard maxLength > 0 else { return nil }
    for length in stride(from: maxLength, through: 1, by: -1) {
      let suffix = String(text.suffix(length))
      if tag.hasPrefix(suffix) { return suffix }
    }
    return nil
  }
}
