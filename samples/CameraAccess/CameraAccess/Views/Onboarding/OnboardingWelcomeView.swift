//
// OnboardingWelcomeView.swift
//
// Step 1 — introduces Lumina with a hero illustration and a single primary CTA.
//

import SwiftUI

struct OnboardingWelcomeView: View {
  var onContinue: () -> Void

  var body: some View {
    VStack(spacing: Spacing.xl) {
      Spacer()

      Image(.cameraAccessIcon)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 140)

      VStack(spacing: Spacing.md) {
        Text("Words worth keeping.")
          .font(.serif(.largeTitle, weight: .bold))
          .foregroundColor(.ink)
          .multilineTextAlignment(.center)

        Text("Lumina watches you read and saves the words you reach for — no typing required.")
          .font(.system(size: 17))
          .foregroundColor(.leather)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, Spacing.lg)
      }

      Spacer()

      CustomButton(title: "Begin", style: .primary, isDisabled: false, action: onContinue)
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.bottom, Spacing.xl)
  }
}
