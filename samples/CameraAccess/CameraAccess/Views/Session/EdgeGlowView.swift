//
// EdgeGlowView.swift
//
// The ambient half of the session screen: a blurred stroke hugging the screen
// edges whose color and breathing answer, from across a room, the only question
// that matters — is Luna idle, listening, thinking, or speaking.
//
// This is deliberately the *only* visual presence the voice conversation has.
// The founder's framing: chat is a natural interface and stays ambient ("kind of
// hidden away"); the screen itself stays formal. So the glow carries state, the
// definition card carries information, and nothing pulses in the reader's face.
//
// Implemented with TimelineView rather than repeatForever animations: the
// breathing period changes with the phase, and TimelineView re-derives opacity
// from the clock each frame, so a phase change retunes the pulse without
// restarting or fighting an in-flight animation.
//

import SwiftUI

struct EdgeGlowView: View {

  let phase: VoiceSessionController.Phase
  let reduceMotion: Bool

  var body: some View {
    let style = GlowStyle(for: phase)

    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || style.amplitude == 0)) { timeline in
      let t = timeline.date.timeIntervalSinceReferenceDate
      let pulse = reduceMotion ? 0.5 : (sin(t * 2 * .pi / style.period) + 1) / 2
      let opacity = style.base + style.amplitude * pulse

      RoundedRectangle(cornerRadius: 44)
        .strokeBorder(style.color, lineWidth: 26)
        .blur(radius: 36)
        .padding(2)
        .opacity(opacity)
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .animation(.easeInOut(duration: 0.4), value: GlowStyle(for: phase))
    .accessibilityHidden(true)
  }
}

/// One phase → one look. Base opacity is what Reduce Motion holds steady at
/// (plus half the amplitude); period is the breathing cycle in seconds.
private struct GlowStyle: Equatable {
  var color: Color
  var base: Double
  var amplitude: Double
  var period: Double

  init(for phase: VoiceSessionController.Phase) {
    switch phase {
    case .listeningIdle:
      // Near-invisible breathing: "I'm here", at a cost of nothing.
      self.init(color: .amber, base: 0.04, amplitude: 0.05, period: 3.0)
    case .awaitingQuestion, .capturingUtterance, .coolingDown:
      self.init(color: .amber, base: 0.28, amplitude: 0.22, period: 2.4)
    case .thinking:
      // Tonally distinct from listening: dimmer, duller, quicker.
      self.init(color: .leather, base: 0.22, amplitude: 0.14, period: 0.9)
    case .responding:
      self.init(color: .amber, base: 0.45, amplitude: 0.28, period: 1.2)
    case .idle, .startingUp, .paused, .ended:
      self.init(color: .amber, base: 0, amplitude: 0, period: 3.0)
    }
  }

  init(color: Color, base: Double, amplitude: Double, period: Double) {
    self.color = color
    self.base = base
    self.amplitude = amplitude
    self.period = period
  }
}
