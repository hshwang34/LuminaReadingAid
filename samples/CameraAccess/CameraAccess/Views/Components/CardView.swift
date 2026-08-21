/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CardView.swift
//
// Reusable container component that provides consistent card styling throughout the app.
//
// Styled in the Pen & Paper language: linen surface, warm ink-tinted shadow. It
// predates the design system (systemBackground + black shadow) and was the one
// surface in the app that still looked like a stock iOS card among paper ones.
//

import SwiftUI

struct CardView<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      content
    }
    .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
    .warmShadow(.subtle)
  }
}
