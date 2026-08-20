//
// OnboardingDeviceChoiceView.swift
//
// Step 4 — the user chooses glasses or phone camera. Glasses path calls
// WearablesViewModel.connectGlasses() and auto-advances when registration
// completes. Phone camera path advances immediately.
//

import MWDATCore
import SwiftUI

struct OnboardingDeviceChoiceView: View {
  @ObservedObject var wearablesViewModel: WearablesViewModel
  var onAdvance: () -> Void

  var body: some View {
    VStack(spacing: Spacing.xl) {
      Spacer(minLength: Spacing.lg)

      Text("How will you read today?")
        .font(.serif(.title, weight: .bold))
        .foregroundColor(.ink)
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.lg)

      VStack(spacing: Spacing.md) {
        DeviceChoiceTile(
          icon: "eyeglasses",
          title: "Meta Ray-Ban Glasses",
          subtitle: "See through your glasses, hands-free.",
          isLoading: wearablesViewModel.registrationState == .registering,
          action: {
            wearablesViewModel.connectGlasses()
          }
        )

        DeviceChoiceTile(
          icon: "iphone",
          title: "Phone Camera",
          subtitle: "Point your phone at the page. Works anywhere.",
          isLoading: false,
          action: onAdvance
        )
      }

      Text("You can switch anytime from the Library tab.")
        .font(.system(size: 13))
        .foregroundColor(.leather)
        .multilineTextAlignment(.center)

      Spacer()
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.bottom, Spacing.xl)
    .onChange(of: wearablesViewModel.registrationState) { _, newValue in
      if newValue == .registered {
        wearablesViewModel.showGettingStartedSheet = false
        onAdvance()
      }
    }
    .onChange(of: wearablesViewModel.showGettingStartedSheet) { _, newValue in
      if newValue {
        wearablesViewModel.showGettingStartedSheet = false
        onAdvance()
      }
    }
  }
}

private struct DeviceChoiceTile: View {
  let icon: String
  let title: String
  let subtitle: String
  let isLoading: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Spacing.lg) {
        Image(systemName: icon)
          .font(.system(size: 28, weight: .regular))
          .foregroundColor(.ink)
          .frame(width: 44)

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(title)
            .font(.serif(.headline, weight: .semibold))
            .foregroundColor(.ink)
          Text(subtitle)
            .font(.system(size: 14))
            .foregroundColor(.leather)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer()

        if isLoading {
          ProgressView()
            .tint(.leather)
        } else {
          Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.leather)
        }
      }
      .padding(Spacing.lg)
      .background(Color.linen)
      .cornerRadius(CornerRadius.card)
      .warmShadow(.medium)
    }
    .buttonStyle(.plain)
    .disabled(isLoading)
  }
}
