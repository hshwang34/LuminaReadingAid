//
// OnboardingViewModel.swift
//
// Drives the first-launch onboarding flow. Owns the current step and persists
// progress to UserDefaults. Four steps: welcome, the live wake-phrase demo
// (where mic + speech permissions are granted), the Lock Screen entry-point
// teach, and notifications. A stale persisted step from the old six-step flow
// fails OnboardingStep(rawValue:) and falls back to .welcome.
//

import Foundation
import SwiftUI

enum OnboardingStep: String, CaseIterable {
  case welcome
  case wakeDemo
  case widgetTeach
  case notifications

  /// Steps that show the progress dots header (welcome is standalone-feel).
  var showsProgressDots: Bool {
    switch self {
    case .wakeDemo, .widgetTeach, .notifications: return true
    case .welcome: return false
    }
  }

  /// Position used by the progress dots indicator (1-indexed within the dotted steps).
  var dotIndex: Int {
    switch self {
    case .welcome: return 0
    case .wakeDemo: return 1
    case .widgetTeach: return 2
    case .notifications: return 3
    }
  }

  static var dotCount: Int { 3 }
}

@MainActor
final class OnboardingViewModel: ObservableObject {
  @Published var currentStep: OnboardingStep

  static let hasCompletedKey = "hasCompletedOnboarding"
  static let lastStepKey = "onboardingLastStep"

  init() {
    if let raw = UserDefaults.standard.string(forKey: Self.lastStepKey),
       let step = OnboardingStep(rawValue: raw) {
      self.currentStep = step
    } else {
      self.currentStep = .welcome
    }
  }

  func advance() {
    let all = OnboardingStep.allCases
    guard let idx = all.firstIndex(of: currentStep) else { return }
    let next = idx + 1
    if next >= all.count {
      complete()
    } else {
      currentStep = all[next]
      UserDefaults.standard.set(currentStep.rawValue, forKey: Self.lastStepKey)
    }
  }

  func complete() {
    UserDefaults.standard.set(true, forKey: Self.hasCompletedKey)
    UserDefaults.standard.removeObject(forKey: Self.lastStepKey)
  }
}
