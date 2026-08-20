//
// HandednessPickerView.swift
//
// Step 3 — mandatory. User picks their dominant hand so AnchorTrackingService
// can derive the page vertical axis from the non-occluded edge.
//

import SwiftUI

struct HandednessPickerView: View {
  let selection: Handedness?
  var onSelect: (Handedness) -> Void
  var onContinue: () -> Void

  @State private var localSelection: Handedness?

  init(selection: Handedness?, onSelect: @escaping (Handedness) -> Void, onContinue: @escaping () -> Void) {
    self.selection = selection
    self.onSelect = onSelect
    self.onContinue = onContinue
    self._localSelection = State(initialValue: selection)
  }

  var body: some View {
    VStack(spacing: Spacing.xl) {
      Spacer(minLength: Spacing.lg)

      VStack(spacing: Spacing.md) {
        Text("Which hand do you read with?")
          .font(.serif(.title, weight: .bold))
          .foregroundColor(.ink)
          .multilineTextAlignment(.center)

        Text("Lumina uses this to track the page accurately while your hand is in frame.")
          .font(.system(size: 15))
          .foregroundColor(.leather)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, Spacing.md)
      }

      HStack(spacing: Spacing.lg) {
        HandednessCardView(
          handedness: .left,
          isSelected: localSelection == .left
        ) {
          localSelection = .left
          onSelect(.left)
        }
        HandednessCardView(
          handedness: .right,
          isSelected: localSelection == .right
        ) {
          localSelection = .right
          onSelect(.right)
        }
      }

      Spacer()

      CustomButton(
        title: "Continue",
        style: .primary,
        isDisabled: localSelection == nil,
        action: onContinue
      )
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.bottom, Spacing.xl)
  }
}

private struct HandednessCardView: View {
  let handedness: Handedness
  let isSelected: Bool
  let action: () -> Void

  private var label: String {
    handedness == .left ? "Left" : "Right"
  }

  private var iconName: String {
    // `hand.draw` ships with a right-hand glyph; mirror it for .left.
    "hand.draw.fill"
  }

  var body: some View {
    Button(action: action) {
      VStack(spacing: Spacing.md) {
        Image(systemName: iconName)
          .resizable()
          .scaledToFit()
          .frame(width: 56, height: 56)
          .foregroundColor(isSelected ? .parchment : .ink)
          .scaleEffect(x: handedness == .left ? -1 : 1, y: 1)

        Text(label)
          .font(.serif(.headline, weight: .semibold))
          .foregroundColor(isSelected ? .parchment : .ink)
      }
      .frame(maxWidth: .infinity)
      .frame(height: 140)
      .background(isSelected ? Color.ink : Color.linen)
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.card)
          .stroke(isSelected ? Color.amber : Color.leather.opacity(0.3),
                  lineWidth: isSelected ? 2 : 1)
      )
      .cornerRadius(CornerRadius.card)
      .warmShadow(isSelected ? .medium : .subtle)
    }
    .buttonStyle(.plain)
    .animation(.easeInOut(duration: 0.2), value: isSelected)
  }
}
