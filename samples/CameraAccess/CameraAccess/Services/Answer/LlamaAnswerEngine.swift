//
// LlamaAnswerEngine.swift
//
// The llama.cpp-backed implementation of AnswerEngine.
//
// Three things here are load-bearing for the product:
//
//  1. GRAMMAR. Every generation is constrained by a GBNF grammar, so the model cannot
//     emit anything but the expected JSON object. With a 1.7B model this is the
//     difference between "usually parses" and "always parses" — and it means the
//     first token is guaranteed to be `{`, which makes a <think> block structurally
//     impossible regardless of what the chat template does.
//
//  2. PREFIX CACHE. The system prompt is decoded once per session and its KV entries
//     are kept; each question only removes and re-decodes the turn that follows it.
//     That takes ~150 tokens of prefill off the latency path of every question.
//
//  3. MMAP. The model is loaded with LLAMA_LOAD_MODE_MMAP so its weights are clean,
//     file-backed pages the OS can evict and re-fault. The reading session sits
//     backgrounded for an hour; mlock'd weights would make it a Jetsam target.
//
// The type is an actor because a llama context is not thread-safe. The generation
// loop yields between tokens so the actor stays responsive to cancellation — barge-in
// has to be able to stop speech mid-answer.
//

import Foundation
import os
import LlamaSwift
import UIKit

actor LlamaAnswerEngine: AnswerEngine {

  static let shared = LlamaAnswerEngine()

  // MARK: - State

  private var model: OpaquePointer?
  private var context: OpaquePointer?
  private var vocab: OpaquePointer?

  /// Number of tokens of system prefix currently resident in the KV cache, and which
  /// prompt mode produced them. A different mode means a different system prompt,
  /// which invalidates the cached prefix.
  private var cachedPrefixTokens: Int32 = 0
  private var cachedPrefixMode: AnswerPrompt.Mode?

  private var state: AnswerEngineReadiness = .notReady

  /// Bumped to supersede an in-flight generation. The loop compares against its own
  /// captured id, so both `cancelCurrent()` and a newer question stop the old one.
  private var generationID: UInt64 = 0

  /// Holds bytes that end mid-UTF8-sequence: a multi-byte character can straddle two
  /// tokens, and decoding half of one produces mojibake in the spoken answer.
  private var pendingBytes: [UInt8] = []

  /// Consecutive fatal decode failures. One is usually recoverable by clearing the
  /// KV cache; a second means the context itself is wedged and only a reload helps.
  private var consecutiveDecodeFailures = 0

  private static var backendInitialized = false

  private let contextTokens: UInt32 = 2048
  private let batchTokens: UInt32 = 512

  // MARK: - Compute placement

  /// How many layers to offload to Metal. 99 means all of them; 0 means CPU only.
  ///
  /// **Defaults to 0, and that is a product decision rather than a tuning choice.**
  ///
  /// iOS refuses to execute GPU work for an app that is not frontmost. A Metal command
  /// buffer submitted from the background fails with
  /// `kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`, llama.cpp
  /// reports `llama_decode returned -3`, and — worse — the ggml Metal backend latches
  /// into an error state that survives until the context is recreated. So Metal makes
  /// answers fast in the hand and impossible with the phone locked, and the locked
  /// phone is the scenario the whole architecture exists to serve.
  ///
  /// CPU inference is slower but has no such restriction, which makes it the only
  /// setting where the app behaves the same way in every state it can be in.
  ///
  /// Measured on an iPhone 14 Pro: Metal is one to two seconds faster per answer, and
  /// that is not worth a feature that fails outright in the state the app is designed
  /// to be used in. Shipping builds are CPU-only and cannot be configured otherwise —
  /// the override exists so the two can still be compared on device.
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

  /// Threads for CPU inference.
  ///
  /// Fewer than the core count on purpose. An A16 has two performance cores and four
  /// efficiency cores; spreading a decode across all six makes every step wait on the
  /// slowest thread, so the efficiency cores cost throughput rather than adding it.
  private let threads: Int32 = 4

  /// Change the offload setting and reload the model so it takes effect.
  func setGPULayers(_ layers: Int32) async throws {
    guard Self.gpuLayers != layers else { return }
    Self.gpuLayers = layers
    guard LlamaModelStore.shared.isModelPresent else { return }
    let url = LlamaModelStore.shared.modelFileURL
    state = .loading
    do {
      try loadModel(at: url)
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
      // Report anyway. A caller that attached only now has never seen a callback, and
      // returning in silence leaves it believing the model is still unavailable — which
      // is exactly what a second session, or any caller after the debug harness has
      // already loaded the model, would conclude.
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
      Log.llm.info("model loaded in \(Int(Date().timeIntervalSince(loadStarted) * 1000), privacy: .public) ms — \(Self.gpuLayers, privacy: .public) GPU layers")

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
  /// not the model — so this is also the recovery path after a backend failure, and it
  /// is far cheaper than re-reading a gigabyte of weights.
  private func makeContext() throws {
    guard let model else { throw AnswerEngineError.modelUnavailable }

    if let context { llama_free(context) }
    context = nil
    cachedPrefixTokens = 0
    cachedPrefixMode = nil

    var ctxParams = llama_context_default_params()
    ctxParams.n_ctx = contextTokens
    ctxParams.n_batch = batchTokens
    ctxParams.n_threads = threads
    ctxParams.n_threads_batch = threads

    guard let ctx = llama_init_from_model(model, ctxParams) else {
      throw AnswerEngineError.modelLoadFailed("could not create context")
    }
    context = ctx
  }

  /// Frees the model. Called on memory pressure while the session is idle; the next
  /// question pays the reload.
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
    cachedPrefixMode = nil
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

    let generationStarted = Date()
    Log.llm.info("generation started — mode \(String(describing: prompt.mode), privacy: .public), word \"\(prompt.word ?? "-", privacy: .public)\"")

    // ── Prompt assembly, with prefix reuse ─────────────────────────────────
    if cachedPrefixMode != prompt.mode {
      // Different contract → different system prompt → the cached prefix is wrong.
      // Clearing sequence 0 from position 0 empties the cache; this app only ever
      // uses one sequence, and seq_rm is the call already verified against the
      // package's headers.
      llama_memory_seq_rm(llama_get_memory(context), 0, 0, -1)
      let prefix = tokenize(PromptBuilder.systemPrefix(for: prompt.mode), addSpecial: true)
      try decode(prefix)
      cachedPrefixTokens = Int32(prefix.count)
      cachedPrefixMode = prompt.mode
      Log.llm.info("system prefix decoded fresh — \(prefix.count, privacy: .public) tokens")
    } else {
      // Keep the system prefix, drop everything after it.
      llama_memory_seq_rm(llama_get_memory(context), 0, cachedPrefixTokens, -1)
      Log.llm.info("system prefix reused from KV cache — \(self.cachedPrefixTokens, privacy: .public) tokens skipped")
    }

    let turn = tokenize(PromptBuilder.turnSuffix(for: prompt), addSpecial: false)
    guard cachedPrefixTokens + Int32(turn.count) + Int32(PromptBuilder.maxTokens(for: prompt.mode))
            < Int32(contextTokens) else {
      throw AnswerEngineError.generationFailed("prompt too long for context")
    }
    try decode(turn)
    Log.llm.info("prefill done — \(turn.count, privacy: .public) turn tokens in \(Int(Date().timeIntervalSince(generationStarted) * 1000), privacy: .public) ms")

    // ── Sampler: grammar first so it masks the logits, then greedy ─────────
    let chainParams = llama_sampler_chain_default_params()
    guard let chain = llama_sampler_chain_init(chainParams) else {
      throw AnswerEngineError.generationFailed("sampler chain")
    }
    defer { llama_sampler_free(chain) }

    guard let grammar = llama_sampler_init_grammar(
      vocab, PromptBuilder.grammar(for: prompt.mode), "root"
    ) else {
      throw AnswerEngineError.generationFailed("grammar rejected by llama.cpp")
    }
    llama_sampler_chain_add(chain, grammar)
    llama_sampler_chain_add(chain, llama_sampler_init_greedy())

    // ── Decode loop ─────────────────────────────────────────────────────────
    var scanner = StreamingJSONFieldScanner(
      expected: prompt.mode == .followUp ? AnswerSchema.followUpKeys : AnswerSchema.groundedKeys
    )
    var splitter = ClauseSplitter()
    var produced = 0
    let limit = PromptBuilder.maxTokens(for: prompt.mode)

    while produced < limit {
      guard myID == generationID else { throw AnswerEngineError.cancelled }
      try Task.checkCancellation()

      // llama_sampler_sample() applies the chain, selects a token, AND accepts it into
      // the chain's state. Calling llama_sampler_accept() again here would advance the
      // grammar a second time over the same token, which empties its stack and
      // aborts — the C++ side throws rather than returning an error.
      let token = llama_sampler_sample(chain, context, -1)
      if llama_vocab_is_eog(vocab, token) { break }

      let text = decodePiece(token)
      if !text.isEmpty {
        for field in scanner.consume(text) {
          emit(field, mode: prompt.mode, splitter: &splitter, into: continuation)
        }
      }

      try decode([token])
      produced += 1

      // Lets cancellation and a superseding question actually reach this actor.
      await Task.yield()
    }

    let decodeSeconds = Date().timeIntervalSince(generationStarted)
    Log.llm.info("generation done — \(produced, privacy: .public) tokens in \(Int(decodeSeconds * 1000), privacy: .public) ms (\(String(format: "%.1f", Double(produced) / max(decodeSeconds, 0.001)), privacy: .public) tok/s)")

    if let tail = splitter.flush() {
      continuation.yield(.speakable(tail))
    }

    // ── Authoritative result ────────────────────────────────────────────────
    // The incremental events exist for latency; this decode is what the app trusts.
    if prompt.mode == .followUp {
      let answer = try scanner.decode(FollowUpAnswer.self)
      continuation.yield(.final(.followUp(answer)))
    } else {
      let raw = try scanner.decode(GroundedAnswer.self)
      continuation.yield(.final(.grounded(raw.validated(againstSenseCount: prompt.candidateSenses.count))))
    }
  }

  /// Routes a completed JSON field to the UI and, where it is speech, to TTS.
  private func emit(
    _ field: StreamingJSONFieldScanner.Emitted,
    mode: AnswerPrompt.Mode,
    splitter: inout ClauseSplitter,
    into continuation: AsyncThrowingStream<AnswerStreamEvent, Error>.Continuation
  ) {
    switch field.key {
    case "sense_id":
      if let id = Int(field.value) { continuation.yield(.field(.senseID(id))) }

    case "short_gloss":
      continuation.yield(.field(.gloss(field.value)))
      speak(field.value, splitter: &splitter, into: continuation)

    case "example":
      continuation.yield(.field(.example(field.value)))
      speak(field.value, splitter: &splitter, into: continuation)

    case "answer":
      continuation.yield(.field(.followUpAnswer(field.value)))
      speak(field.value, splitter: &splitter, into: continuation)

    case "confidence":
      if let confidence = GroundedAnswer.Confidence(rawValue: field.value) {
        continuation.yield(.field(.confidence(confidence)))
      }

    default:
      break
    }
  }

  private func speak(
    _ text: String,
    splitter: inout ClauseSplitter,
    into continuation: AsyncThrowingStream<AnswerStreamEvent, Error>.Continuation
  ) {
    for clause in splitter.consume(text + " ") {
      continuation.yield(.speakable(clause))
    }
  }

  // MARK: - Failure recovery

  /// Put the context back into a usable state after a fatal decode.
  ///
  /// Without this, one failure ends the session: the prefix cache still claims tokens
  /// that the failed batch may have left half-written, so every subsequent question
  /// decodes into a corrupted context and fails the same way until the app is
  /// relaunched. The reader experiences that as "Luna stopped working", which is a
  /// far worse outcome than one slow answer.
  private func recoverFromDecodeFailure() {
    consecutiveDecodeFailures += 1
    pendingBytes.removeAll(keepingCapacity: true)

    // ggml states the requirement outright: "backend is in error state from a previous
    // command buffer failure - recreate the backend to recover". Clearing the KV cache
    // is not enough and never was — the backend lives with the context, so the context
    // has to be rebuilt. Without this, a single failed decode ends the app's ability to
    // answer anything until it is relaunched, which is how one locked-screen question
    // turned into "the model stopped working".
    do {
      try makeContext()
    } catch {
      unloadLocked()
      state = .notReady
      consecutiveDecodeFailures = 0
      return
    }

    // A fresh context that fails again is not a transient fault. Drop the model so the
    // next question pays a full reload rather than failing a third time.
    if consecutiveDecodeFailures >= 3 {
      unloadLocked()
      state = .notReady
      consecutiveDecodeFailures = 0
    }
  }

  /// Adds the reason to a decode failure when the reason is knowable.
  ///
  /// `llama_decode returned -3` on its own sends anyone reading it into llama.cpp's
  /// source. On iOS it almost always means one specific thing, and saying so is the
  /// difference between a five-minute diagnosis and an afternoon.
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
      // Negative return is the negated required capacity.
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
