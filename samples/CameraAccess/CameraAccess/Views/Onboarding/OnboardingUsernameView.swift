//
// OnboardingUsernameView.swift
//
// Step 2 — optional name collection stored in UserDefaults["userName"].
//

import SwiftUI

struct OnboardingUsernameView: View {
  @Binding var username: String
  var onContinue: () -> Void
  var onSkip: () -> Void

  @FocusState private var isFieldFocused: Bool

  var body: some View {
    VStack(spacing: Spacing.xl) {
      Spacer(minLength: Spacing.xl)

      VStack(spacing: Spacing.md) {
        Text("What should we call you?")
          .font(.serif(.title, weight: .bold))
          .foregroundColor(.ink)
          .multilineTextAlignment(.center)

        Text("We never share this. It lives only on your device.")
          .font(.system(size: 13))
          .foregroundColor(.leather)
          .multilineTextAlignment(.center)
      }

      TextField("Your name", text: $username)
        .textContentType(.givenName)
        .autocorrectionDisabled()
        .font(.serif(.title3))
        .foregroundColor(.ink)
        .padding(Spacing.lg)
        .background(Color.linen)
        .cornerRadius(CornerRadius.card)
        .warmShadow(.subtle)
        .focused($isFieldFocused)

      Spacer()

      VStack(spacing: Spacing.md) {
        CustomButton(
          title: "Continue",
          style: .primary,
          isDisabled: username.trimmingCharacters(in: .whitespaces).isEmpty,
          action: onContinue
        )
        CustomButton(title: "Skip for now", style: .secondary, isDisabled: false, action: onSkip)
      }
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.bottom, Spacing.xl)
    .onAppear { isFieldFocused = true }
  }
}
