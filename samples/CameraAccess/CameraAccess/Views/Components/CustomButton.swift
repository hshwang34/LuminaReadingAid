/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CustomButton.swift
//
// Reusable button component used throughout the CameraAccess app for consistent styling.
//

import SwiftUI

struct CustomButton: View {
  let title: String
  let style: ButtonStyle
  let isDisabled: Bool
  let action: () -> Void

  enum ButtonStyle {
    case primary, secondary, destructive

    var backgroundColor: Color {
      switch self {
      case .primary:
        return .amber
      case .secondary:
        return .linen
      case .destructive:
        return .brick.opacity(0.12)
      }
    }

    var foregroundColor: Color {
      switch self {
      case .primary:
        // White holds on marigold in both light and dark — the accent is the
        // constant, not the scheme.
        return .white
      case .secondary:
        return .ink
      case .destructive:
        return .brick
      }
    }
  }

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 15, weight: .semibold))
        .foregroundColor(style.foregroundColor)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .background(style.backgroundColor, in: RoundedRectangle(cornerRadius: CornerRadius.button))
        .overlay(
          RoundedRectangle(cornerRadius: CornerRadius.button)
            .strokeBorder(.hairline, lineWidth: style == .secondary ? 1 : 0)
        )
    }
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.6 : 1.0)
  }
}
