//
// OnboardingWidgetTeachView.swift
//
// Step 3 — the instant entry points. Starting a session should feel like
// starting a timer: one tap from the Lock Screen. iOS has no reliable deep link
// into Control Center customization, so this teaches the add-once flow instead.
//

import SwiftUI

struct OnboardingWidgetTeachView: View {
  var onContinue: () -> Void

  var body: some View {
    VStack(spacing: Spacing.xl) {
      Spacer(minLength: Spacing.lg)

      ZStack {
        RoundedRectangle(cornerRadius: 24)
          .fill(.linen)
          .frame(width: 132, height: 132)
          .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.hairline, lineWidth: 1))
        Image(systemName: "waveform.and.mic")
          .font(.system(size: 48))
          .foregroundStyle(.amber)
      }

      VStack(spacing: Spacing.md) {
        Text("One tap from the Lock Screen")
          .font(.screenTitle)
          .foregroundStyle(.ink)
          .multilineTextAlignment(.center)

        Text("Add Luna's control once, and every session starts like a timer — no unlocking, no searching for the app.")
          .font(.subheadline)
          .foregroundStyle(.leather)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, Spacing.md)

      VStack(alignment: .leading, spacing: Spacing.md) {
        step(1, "Hold the Lock Screen, tap Customize")
        step(2, "Choose a control slot, search \u{201C}Reading Session\u{201D}")
        step(3, "Tap it any time — Luna opens listening")
      }
      .padding(Spacing.lg)
      .frame(maxWidth: .infinity, alignment: .leading)
      .hairlineCard()

      Text("There's a Home Screen widget too — long-press your Home Screen to add it.")
        .font(.caption)
        .foregroundStyle(.leather.opacity(0.8))
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.md)

      Spacer()

      CustomButton(title: "Got It", style: .primary, isDisabled: false, action: onContinue)
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.bottom, Spacing.xl)
  }

  private func step(_ number: Int, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
      Text("\(number)")
        .font(.stat(15))
        .foregroundStyle(.amber)
        .frame(width: 18)
      Text(text)
        .font(.subheadline)
        .foregroundStyle(.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
