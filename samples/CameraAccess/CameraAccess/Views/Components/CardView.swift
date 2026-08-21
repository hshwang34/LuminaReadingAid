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
// Notebook Minimal: a flat cloud surface whose edge is a hairline border, not a
// shadow. The one shared card container — screens that hand-roll their own card
// backgrounds should migrate to `.hairlineCard()` as they get touched.
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
    .hairlineCard()
  }
}
