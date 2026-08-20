//
// OnboardingViewModel.swift
//
// Drives the first-launch onboarding flow. Owns the current step, collects user
// choices, and persists them to UserDefaults. The coordinator view observes
// `currentStep` and renders the matching step subview.
//

import Foundation
import SwiftUI

enum OnboardingStep: String, CaseIterable {
  case welcome
  case username
  case handedness
  case deviceChoice
  case gestureDemo
  case notifications

  /// Steps that show the progress dots header (welcome and gestureDemo are standalone-feel).
  var showsProgressDots: Bool {
    switch self {
    case .username, .handedness, .deviceChoice, .notifications: return true
    case .welcome, .gestureDemo: return false
    }
  }

  /// Position used by the progress dots indicator (1-indexed within the dotted steps).
  var dotIndex: Int {
    switch self {
    case .welcome:       return 0
    case .username:      return 1
    case .handedness:    return 2
    case .deviceChoice:  return 3
    case .gestureDemo:   return 3
    case .notifications: return 4
    }
  }

  static var dotCount: Int { 4 }
}

@MainActor
final class OnboardingViewModel: ObservableObject {
  @Published var currentStep: OnboardingStep
  @Published var username: String = ""
  @Published var selectedHandedness: Handedness?

  static let hasCompletedKey = "hasCompletedOnboarding"
  static let lastStepKey = "onboardingLastStep"
  static let usernameKey = "userName"

  init() {
    if let raw = UserDefaults.standard.string(forKey: Self.lastStepKey),
       let step = OnboardingStep(rawValue: raw) {
      self.currentStep = step
    } else {
      self.currentStep = .welcome
    }
    if let handednessRaw = UserDefaults.standard.string(forKey: Handedness.userDefaultsKey),
       let handedness = Handedness(rawValue: handednessRaw) {
      self.selectedHandedness = handedness
    }
    self.username = UserDefaults.standard.string(forKey: Self.usernameKey) ?? ""
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

  func saveUsername() {
    let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    UserDefaults.standard.set(trimmed, forKey: Self.usernameKey)
  }

  func saveHandedness(_ handedness: Handedness) {
    selectedHandedness = handedness
    UserDefaults.standard.set(handedness.rawValue, forKey: Handedness.userDefaultsKey)
  }

  func complete() {
    UserDefaults.standard.set(true, forKey: Self.hasCompletedKey)
    UserDefaults.standard.removeObject(forKey: Self.lastStepKey)
  }
}
