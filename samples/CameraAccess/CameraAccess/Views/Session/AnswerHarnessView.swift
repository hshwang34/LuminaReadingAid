//
// AnswerHarnessView.swift
//
// DEBUG-only bench for the answer pipeline, before any voice input exists.
//
// It types the utterance that the wake word and recogniser will later speak, so the
// whole downstream path — routing, grounding, grammar-constrained generation,
// clause-streamed speech, dedupe and persistence — can be exercised and timed on
// device now rather than after the audio layer lands.
//
// The number to watch is time-to-first-audio. The design is accountable to roughly
// 1.0-1.5s from end of speech to Luna starting to talk, and this harness measures the
// part of that budget the pipeline owns.
//

#if DEBUG

import AVFoundation
import SwiftData
import SwiftUI

struct AnswerHarnessView: View {

  @Environment(\.modelContext) private var modelContext

  @State private var utterance = "what does ephemeral mean"
  @State private var pipeline: AnswerPipeline?
  @State private var tts = AVSpeechTTSEngine()
  @State private var context = SessionContext()

  @State private var readiness: AnswerEngineReadiness = .notReady
  @State private var useMetal = LlamaAnswerEngine.gpuLayers > 0
  @State private var isRunning = false
  @State private var transcript: [Line] = []
  @State private var errorText: String?

  private struct Line: Identifiable {
    let id = UUID()
    let label: String
    let detail: String
    let tone: Tone
    enum Tone { case normal, good, bad }
  }

  private let samples = [
    "what does ephemeral mean",
    "what does divine mean in she divines her way",
    "can you explain what perfunctory means",
    "use it in a sentence",
    "say that again",
    "why is it spelled that way",
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        modelSection
        inputSection
        if let errorText {
          Text(errorText)
            .font(.caption)
            .foregroundStyle(.brick)
        }
        transcriptSection
      }
      .padding(Spacing.lg)
    }
    .background(.parchment)
    .navigationTitle("Answer Harness")
    .navigationBarTitleDisplayMode(.inline)
    .task {
      configureAudioSessionOnce()
      await refreshReadiness()
    }
  }

  // MARK: - Model

  private var modelSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Model").font(.sectionTitle).foregroundStyle(.ink)
      Text(readinessDescription)
        .font(.caption)
        .foregroundStyle(.leather)

      if case .downloading(let progress) = readiness {
        ProgressView(value: progress)
          .tint(.amber)
      }

      HStack(spacing: Spacing.sm) {
        Button("Prepare") { Task { await prepare() } }
          .buttonStyle(.borderedProminent)
          .tint(.ink)
          .disabled(isPreparing)

        Button("Delete model") {
          Task {
            await LlamaModelStore.shared.deleteModel()
            await LlamaAnswerEngine.shared.unload()
            await refreshReadiness()
          }
        }
        .buttonStyle(.bordered)
        .tint(.brick)
      }

      placementControl
    }
  }

  /// Metal vs CPU, on device, without a rebuild.
  ///
  /// Worth a control rather than a constant because the two settings fail in opposite
  /// directions: Metal is several times faster but cannot execute at all once the app
  /// is backgrounded, and the locked phone is the scenario the product is built on.
  /// The only way to choose is to measure both here.
  private var placementControl: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Picker("Compute", selection: $useMetal) {
        Text("CPU only").tag(false)
        Text("Metal").tag(true)
      }
      .pickerStyle(.segmented)
      .disabled(isPreparing)

      Text(useMetal
           ? "Faster, but every answer fails once the phone is locked."
           : "Slower, but answers in every state including locked.")
        .font(.caption2)
        .foregroundStyle(.leather)
    }
    .onChange(of: useMetal) { _, newValue in
      Task {
        errorText = nil
        do {
          try await LlamaAnswerEngine.shared.setGPULayers(newValue ? 99 : 0)
        } catch {
          errorText = error.localizedDescription
        }
        await refreshReadiness()
      }
    }
  }

  private var isPreparing: Bool {
    switch readiness {
    case .downloading, .loading: true
    default: false
    }
  }

  private var readinessDescription: String {
    switch readiness {
    case .notReady:
      let mb = LlamaModelStore.approximateBytes / 1_000_000
      return LlamaModelStore.shared.isModelPresent
        ? "On disk, not loaded."
        : "Not downloaded — about \(mb) MB, one time."
    case .downloading(let p): return "Downloading… \(Int(p * 100))%"
    case .loading: return "Loading into memory…"
    case .ready: return "Ready."
    case .failed(let message): return "Failed: \(message)"
    }
  }

  // MARK: - Input

  private var inputSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Utterance").font(.sectionTitle).foregroundStyle(.ink)

      TextField("what does ephemeral mean", text: $utterance, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Spacing.sm) {
          ForEach(samples, id: \.self) { sample in
            Button(sample) { utterance = sample }
              .font(.caption)
              .padding(.horizontal, Spacing.md)
              .padding(.vertical, Spacing.xs)
              .background(.linen, in: Capsule())
              .foregroundStyle(.ink)
          }
        }
      }

      HStack(spacing: Spacing.sm) {
        Button(isRunning ? "Running…" : "Ask") { Task { await ask() } }
          .buttonStyle(.borderedProminent)
          .tint(.ink)
          .disabled(isRunning || !isReady)

        Button("Stop") {
          tts.stop()
          Task { await LlamaAnswerEngine.shared.cancelCurrent() }
        }
        .buttonStyle(.bordered)

        Button("Reset context") {
          context = SessionContext()
          transcript.removeAll()
        }
        .buttonStyle(.bordered)
      }
    }
  }

  private var isReady: Bool {
    if case .ready = readiness { return true }
    return false
  }

  // MARK: - Transcript

  private var transcriptSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      if !transcript.isEmpty {
        Text("Result").font(.sectionTitle).foregroundStyle(.ink)
      }
      ForEach(transcript) { line in
        VStack(alignment: .leading, spacing: 2) {
          Text(line.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.leather)
          Text(line.detail)
            .font(.subheadline)
            .foregroundStyle(line.tone == .bad ? .brick : (line.tone == .good ? .sage : .ink))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
        .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
      }
    }
  }

  // MARK: - Actions

  /// Configure playback once, not per question.
  ///
  /// Reconfiguring an already-active AVAudioSession is what produces the
  /// `IPCAUClient: can't connect to server (-66748)` noise — the audio unit is torn
  /// down and reconnected underneath the synthesiser. The real voice session takes
  /// this further: it activates `.playAndRecord` once at session start and never
  /// touches it again, because deactivating it while backgrounded would end the
  /// session's ability to keep listening.
  private func configureAudioSessionOnce() {
    let session = AVAudioSession.sharedInstance()
    // Leave a recording-capable category alone. A voice session configures
    // `.playAndRecord` once and depends on it staying that way; downgrading it to
    // `.playback` because the debug tab happened to appear would take the microphone
    // away from a session that is still listening.
    guard session.category != .playback, session.category != .playAndRecord else { return }
    try? session.setCategory(.playback, mode: .spokenAudio)
    try? session.setActive(true)
  }

  private func prepare() async {
    errorText = nil
    do {
      try await LlamaAnswerEngine.shared.prepare { state in
        Task { @MainActor in readiness = state }
      }
    } catch {
      errorText = error.localizedDescription
    }
    await refreshReadiness()
  }

  private func refreshReadiness() async {
    readiness = await LlamaAnswerEngine.shared.readiness
  }

  private func ask() async {
    guard !utterance.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    isRunning = true
    errorText = nil
    defer { isRunning = false }

    let pipeline = pipeline ?? AnswerPipeline(tts: tts, modelContext: modelContext)
    self.pipeline = pipeline

    do {
      let result = try await pipeline.handle(utterance: utterance, context: context)
      context = result.context
      transcript = lines(for: result)
    } catch {
      errorText = error.localizedDescription
    }
  }

  private func lines(for result: AnswerPipeline.TurnResult) -> [Line] {
    var out: [Line] = []

    if let ttfa = result.timeToFirstAudio {
      let ms = Int(ttfa * 1000)
      out.append(Line(
        label: "Time to first audio",
        detail: "\(ms) ms  (budget 1000–1500 ms)",
        tone: ms <= 1500 ? .good : .bad
      ))
    }
    out.append(Line(label: "Total", detail: "\(Int(result.totalTime * 1000)) ms", tone: .normal))

    if !result.spokenText.isEmpty {
      out.append(Line(label: "Answer", detail: result.spokenText, tone: .normal))
    }
    return out
  }
}

#endif
