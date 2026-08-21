/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// MainAppView.swift
//
// The root of the UI, and the owner of the one session controller. The session
// must survive tab switches and view identity churn, so its owner is the view
// that lives exactly as long as the UI does — this one.
//

import MWDATCore
import SwiftData
import SwiftUI

struct MainAppView: View {
  let wearables: WearablesInterface
  @ObservedObject private var viewModel: WearablesViewModel
  @AppStorage(OnboardingViewModel.hasCompletedKey) private var hasCompletedOnboarding: Bool = false
  @Environment(\.modelContext) private var modelContext
  @State private var launchRouter = SessionLaunchRouter.shared
  @State private var sessionController: VoiceSessionController?

  init(wearables: WearablesInterface, viewModel: WearablesViewModel) {
    self.wearables = wearables
    self.viewModel = viewModel
  }

  var body: some View {
    Group {
      if let sessionController {
        RootTabView(sessionController: sessionController)
      } else {
        // One frame at most: the controller is constructed in the task below
        // (init does no audio work — cheap by design).
        Color.parchment.ignoresSafeArea()
      }
    }
    .task {
      guard sessionController == nil else { return }
      sessionController = VoiceSessionController(modelContext: modelContext)
    }
    .fullScreenCover(isPresented: .constant(!hasCompletedOnboarding)) {
      OnboardingCoordinatorView(wearablesViewModel: viewModel) {
        hasCompletedOnboarding = true
      }
      .interactiveDismissDisabled(true)
    }
    .onOpenURL { url in
      launchRouter.handle(url)
    }
  }
}
