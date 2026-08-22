//
// OnboardingWakeDemoView.swift
//
// Step 2 — the product, proven live. The reader grants the microphone and
// speech permissions here (never as a surprise on the Session tab), then
// actually says "Hey Luna" and watches the real edge glow answer. An
// illustration would describe the feature; this demonstrates it works.
//

import SwiftUI

struct OnboardingWakeDemoView: View {
  var onContinue: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private enum DemoState: Equatable {
    case idle          // before permissions
    case listening
    case heard         // wake phrase detected
    case denied(String)
  }

  @State private var state: DemoState = .idle
  @State private var demoTask: Task<Void, Never>?

  // The same stack the real session runs on, scoped to this screen.
  @State private var pipeline = VoiceAudioPipeline()

  var body: some View {
    ZStack {
      EdgeGlowView(phase: glowPhase, reduceMotion: reduceMotion)

      if state == .heard {
        // Success flash — sage, the app's one "correct" color.
        RoundedRectangle(cornerRadius: 44)
          .strokeBorder(.sage, lineWidth: 26)
          .blur(radius: 36)
          .padding(2)
          .ignoresSafeArea()
          .allowsHitTesting(false)
          .transition(.opacity)
      }

      VStack(spacing: Spacing.xl) {
        Spacer()

        switch state {
        case .idle:
          headline("Luna listens for you", body: "During a session the microphone stays open so you never put the book down. Grant it once, then try the wake phrase.")
        case .listening:
          VStack(spacing: Spacing.md) {
            Text("Say \u{201C}Hey Luna\u{201D}")
              .font(.screenTitle)
              .foregroundStyle(.ink)
            Text("Out loud, like you would mid-chapter.")
              .font(.subheadline)
              .foregroundStyle(.leather)
          }
        case .heard:
          VStack(spacing: Spacing.md) {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 44))
              .foregroundStyle(.sage)
            Text("She heard you")
              .font(.screenTitle)
              .foregroundStyle(.ink)
            Text("That's the whole gesture. Ask about any word the same way.")
              .font(.subheadline)
              .foregroundStyle(.leather)
              .multilineTextAlignment(.center)
          }
        case .denied(let message):
          headline("Luna needs the microphone", body: message + "\nYou can enable it in Settings, or continue without the demo.")
        }

        Spacer()

        VStack(spacing: Spacing.md) {
          switch state {
          case .idle:
            CustomButton(title: "Enable and Try It", style: .primary, isDisabled: false) {
              startDemo()
            }
          case .listening:
            Button("Skip for now") { finish() }
              .font(.subheadline)
              .foregroundStyle(.leather)
          case .heard:
            CustomButton(title: "Continue", style: .primary, isDisabled: false) {
              finish()
            }
          case .denied:
            CustomButton(title: "Open Settings", style: .primary, isDisabled: false) {
              if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
              }
            }
            Button("Continue anyway") { finish() }
              .font(.subheadline)
              .foregroundStyle(.leather)
          }
        }
      }
      .padding(.horizontal, Spacing.xl)
      .padding(.bottom, Spacing.xl)
      .animation(.easeInOut(duration: 0.25), value: state)
    }
    .onDisappear { teardown() }
  }

  private var glowPhase: VoiceSessionController.Phase {
    switch state {
    case .listening: .awaitingQuestion
    case .heard: .responding
    default: .idle
    }
  }

  private func headline(_ title: String, body bodyText: String) -> some View {
    VStack(spacing: Spacing.md) {
      Image(systemName: "waveform.and.mic")
        .font(.system(size: 44))
        .foregroundStyle(.amber)
      Text(title)
        .font(.screenTitle)
        .foregroundStyle(.ink)
        .multilineTextAlignment(.center)
      Text(bodyText)
        .font(.subheadline)
        .foregroundStyle(.leather)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func startDemo() {
    demoTask = Task {
      // pipeline.start() owns the permission requests — same path as a session.
      do {
        try await pipeline.start()
      } catch {
        state = .denied(error.localizedDescription)
        return
      }

      let transcriber = UtteranceTranscriber(pipeline: pipeline)
      let spotter = SFSpeechWakeWordSpotter(transcriber: transcriber)
      transcriber.start()
      state = .listening

      for await _ in spotter.startSpotting() {
        break // one wake is the whole demo
      }
      spotter.stopSpotting()
      transcriber.stop()

      guard !Task.isCancelled else { return }
      state = .heard
    }
  }

  private func finish() {
    teardown()
    onContinue()
  }

  private func teardown() {
    demoTask?.cancel()
    demoTask = nil
    // The Session tab starts its own pipeline right after onboarding — leave the
    // audio session clean for it.
    pipeline.stop(deactivateSession: true)
  }
}
