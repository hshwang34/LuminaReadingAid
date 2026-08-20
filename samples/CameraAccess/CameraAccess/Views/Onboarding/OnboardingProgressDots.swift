//
// OnboardingProgressDots.swift
//
// Small amber dot indicator showing progress through the dotted onboarding steps.
//

import SwiftUI

struct OnboardingProgressDots: View {
  let count: Int
  let activeIndex: Int

  var body: some View {
    HStack(spacing: Spacing.sm) {
      ForEach(0..<count, id: \.self) { idx in
        Circle()
          .fill(idx <= activeIndex ? Color.amber : Color.leather.opacity(0.3))
          .frame(width: 6, height: 6)
      }
    }
    .animation(.easeInOut(duration: 0.25), value: activeIndex)
  }
}
