//
// OnboardingNotificationsView.swift
//
// Step 6 — final screen. Pre-prompt explaining daily review reminders, then
// triggers the system notification authorization dialog on "Allow reminders".
// Both outcomes (grant, deny, skip) complete onboarding.
//

import SwiftUI
import UserNotifications

struct OnboardingNotificationsView: View {
  var onFinish: () -> Void

  var body: some View {
    VStack(spacing: Spacing.xl) {
      Spacer(minLength: Spacing.lg)

      ZStack {
        Circle()
          .fill(Color.amber.opacity(0.2))
          .frame(width: 120, height: 120)
        Image(systemName: "book.closed.fill")
          .font(.system(size: 52))
          .foregroundColor(.ink)
      }

      VStack(spacing: Spacing.md) {
        Text("Remember what you meant to learn.")
          .font(.serif(.title, weight: .bold))
          .foregroundColor(.ink)
          .multilineTextAlignment(.center)

        VStack(alignment: .leading, spacing: Spacing.sm) {
          bulletRow("Daily review takes under two minutes.")
          bulletRow("We only notify when words are ready to review.")
          bulletRow("Quiet hours are always respected.")
        }
        .padding(.top, Spacing.sm)
      }
      .padding(.horizontal, Spacing.md)

      Spacer()

      VStack(spacing: Spacing.md) {
        CustomButton(title: "Allow reminders", style: .primary, isDisabled: false) {
          requestPermission()
        }
        CustomButton(title: "Not now", style: .secondary, isDisabled: false, action: onFinish)
      }
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.bottom, Spacing.xl)
  }

  private func bulletRow(_ text: String) -> some View {
    HStack(alignment: .top, spacing: Spacing.md) {
      Circle()
        .fill(Color.amber)
        .frame(width: 6, height: 6)
        .padding(.top, 7)
      Text(text)
        .font(.system(size: 15))
        .foregroundColor(.leather)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
  }

  private func requestPermission() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
      Task { @MainActor in onFinish() }
    }
  }
}
