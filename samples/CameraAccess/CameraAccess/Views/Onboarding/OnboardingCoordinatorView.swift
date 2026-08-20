//
// OnboardingCoordinatorView.swift
//
// Root of the first-launch onboarding flow. Routes to the current step view
// and supplies the shared OnboardingViewModel. Mounted as a fullScreenCover
// over MainAppView when `hasCompletedOnboarding` is false.
//

import SwiftUI

struct OnboardingCoordinatorView: View {
  @StateObject private var viewModel = OnboardingViewModel()
  @ObservedObject var wearablesViewModel: WearablesViewModel
  var onComplete: () -> Void

  var body: some View {
    ZStack {
      Color.parchment.ignoresSafeArea()

      VStack(spacing: 0) {
        if viewModel.currentStep.showsProgressDots {
          OnboardingProgressDots(
            count: OnboardingStep.dotCount,
            activeIndex: viewModel.currentStep.dotIndex - 1
          )
          .padding(.top, Spacing.xl)
          .padding(.bottom, Spacing.lg)
        }

        stepContent
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
          ))
          .animation(.easeInOut(duration: 0.28), value: viewModel.currentStep)
      }
    }
  }

  @ViewBuilder
  private var stepContent: some View {
    switch viewModel.currentStep {
    case .welcome:
      OnboardingWelcomeView(onContinue: { viewModel.advance() })
    case .username:
      OnboardingUsernameView(
        username: $viewModel.username,
        onContinue: {
          viewModel.saveUsername()
          viewModel.advance()
        },
        onSkip: { viewModel.advance() }
      )
    case .handedness:
      HandednessPickerView(
        selection: viewModel.selectedHandedness,
        onSelect: { viewModel.saveHandedness($0) },
        onContinue: { viewModel.advance() }
      )
    case .deviceChoice:
      OnboardingDeviceChoiceView(
        wearablesViewModel: wearablesViewModel,
        onAdvance: { viewModel.advance() }
      )
    case .gestureDemo:
      GestureDemoView(
        handedness: viewModel.selectedHandedness ?? .right,
        onContinue: { viewModel.advance() }
      )
    case .notifications:
      OnboardingNotificationsView(
        onFinish: {
          viewModel.complete()
          onComplete()
        }
      )
    }
  }
}
