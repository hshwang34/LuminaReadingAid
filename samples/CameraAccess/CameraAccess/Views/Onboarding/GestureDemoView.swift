//
// GestureDemoView.swift
//
// Step 5 — teaches the two capture gestures via a looping SwiftUI animation.
// Phase 1: quick pinch over a word. Phase 2: sustained pinch + drag across a line.
// The animated hand is mirrored when handedness == .left.
//

import SwiftUI

struct GestureDemoView: View {
  let handedness: Handedness
  var onContinue: () -> Void

  @State private var phase: DemoPhase = .pinchWord
  @State private var animationProgress: CGFloat = 0
  @State private var timer: Timer?

  private enum DemoPhase: Int { case pinchWord = 0, dragHighlight = 1 }

  var body: some View {
    VStack(spacing: Spacing.xl) {
      Spacer(minLength: Spacing.md)

      VStack(spacing: Spacing.sm) {
        Text("Two gestures. That's it.")
          .font(.serif(.title, weight: .bold))
          .foregroundColor(.ink)
          .multilineTextAlignment(.center)

        Text(phase == .pinchWord
             ? "Quick pinch above a word to capture it."
             : "Hold and drag across a line to highlight a passage.")
          .font(.system(size: 15))
          .foregroundColor(.leather)
          .multilineTextAlignment(.center)
          .frame(height: 40)
          .padding(.horizontal, Spacing.lg)
          .animation(.easeInOut(duration: 0.25), value: phase)
      }

      practiceCard
        .frame(height: 260)

      HStack(spacing: Spacing.sm) {
        phaseDot(isActive: phase == .pinchWord)
        phaseDot(isActive: phase == .dragHighlight)
      }

      Spacer()

      VStack(spacing: Spacing.md) {
        CustomButton(title: "Got it", style: .primary, isDisabled: false, action: onContinue)
        CustomButton(title: "Replay", style: .secondary, isDisabled: false) {
          restart()
        }
      }
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.bottom, Spacing.xl)
    .onAppear { start() }
    .onDisappear { stop() }
  }

  private func phaseDot(isActive: Bool) -> some View {
    Circle()
      .fill(isActive ? Color.amber : Color.leather.opacity(0.3))
      .frame(width: 8, height: 8)
      .animation(.easeInOut(duration: 0.2), value: isActive)
  }

  // MARK: - Practice Card

  private var practiceCard: some View {
    GeometryReader { geo in
      let w = geo.size.width
      let h = geo.size.height
      let flip: CGFloat = handedness == .left ? -1 : 1

      ZStack {
        RoundedRectangle(cornerRadius: CornerRadius.card)
          .fill(Color.linen)
          .warmShadow(.medium)

        VStack(alignment: .leading, spacing: Spacing.md) {
          Text("reading, like remembering,")
            .font(.serif(.title3))
            .foregroundColor(.ink)
            .overlay(alignment: .bottom) {
              if phase == .pinchWord && animationProgress > 0.55 {
                Rectangle()
                  .fill(Color.amber)
                  .frame(height: 2)
                  .frame(width: 52)
                  .offset(x: -10, y: 4)
                  .transition(.opacity)
              }
            }
          Text("begins with a single")
            .font(.serif(.title3))
            .foregroundColor(.ink)
            .overlay(alignment: .bottomLeading) {
              if phase == .dragHighlight {
                Rectangle()
                  .fill(Color.amber)
                  .frame(width: dragWidth(for: w), height: 2)
                  .offset(y: 4)
                  .animation(.easeInOut(duration: 0.05), value: animationProgress)
              }
            }
          Text("word held in mind.")
            .font(.serif(.title3))
            .foregroundColor(.ink)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        // Animated hand
        handGlyph(flip: flip, containerSize: CGSize(width: w, height: h))
      }
    }
  }

  private func dragWidth(for cardWidth: CGFloat) -> CGFloat {
    let maxWidth: CGFloat = 160
    let t = max(0, min(1, (animationProgress - 0.1) / 0.7))
    return maxWidth * t
  }

  @ViewBuilder
  private func handGlyph(flip: CGFloat, containerSize: CGSize) -> some View {
    let w = containerSize.width
    let h = containerSize.height

    let (xFraction, yFraction, isPinched) = handPosition()
    let x = w * xFraction
    let y = h * yFraction

    ZStack {
      Image(systemName: isPinched ? "hand.pinch.fill" : "hand.point.up.left.fill")
        .font(.system(size: 44))
        .foregroundColor(.ink)
        .scaleEffect(x: flip, y: 1)
        .shadow(color: .ink.opacity(0.2), radius: 4, y: 2)

      if isPinched && phase == .pinchWord && animationProgress > 0.5 && animationProgress < 0.7 {
        Circle()
          .fill(Color.amber.opacity(0.6))
          .frame(width: 24, height: 24)
          .scaleEffect(1 + (animationProgress - 0.5) * 4)
          .opacity(Double(1 - (animationProgress - 0.5) * 5))
      }
    }
    .position(x: handedness == .left ? (w - x) : x, y: y)
    .animation(.easeInOut(duration: 0.05), value: animationProgress)
  }

  /// Returns (x fraction, y fraction in right-handed coords, isPinched) for the current progress.
  private func handPosition() -> (CGFloat, CGFloat, Bool) {
    switch phase {
    case .pinchWord:
      // Slide in, pinch above word, release.
      let slide = min(animationProgress / 0.5, 1)
      let x = 0.15 + slide * 0.18   // 0.15 → 0.33
      let y: CGFloat = 0.28
      let pinched = animationProgress > 0.45 && animationProgress < 0.85
      return (x, y, pinched)
    case .dragHighlight:
      // Start at left of line 2, pinch, drag right.
      let y: CGFloat = 0.55
      if animationProgress < 0.2 {
        return (0.12, y, false)
      } else if animationProgress < 0.9 {
        let t = (animationProgress - 0.2) / 0.7
        return (0.12 + t * 0.55, y, true)
      } else {
        return (0.67, y, false)
      }
    }
  }

  // MARK: - Timing

  private func start() {
    restart()
  }

  private func restart() {
    stop()
    phase = .pinchWord
    animationProgress = 0
    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
      Task { @MainActor in tick() }
    }
  }

  private func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func tick() {
    animationProgress += 1.0 / 30.0 / 2.5  // 2.5s per phase
    if animationProgress >= 1.0 {
      animationProgress = 0
      phase = phase == .pinchWord ? .dragHighlight : .pinchWord
    }
  }
}
