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
// Central navigation hub that displays different views based on DAT SDK registration and device states.
// When unregistered, shows the registration flow. When registered, shows the device selection screen
// for choosing which Meta wearable device to stream from.
//

import MWDATCore
import SwiftUI

struct MainAppView: View {
  let wearables: WearablesInterface
  @ObservedObject private var viewModel: WearablesViewModel
  @AppStorage(OnboardingViewModel.hasCompletedKey) private var hasCompletedOnboarding: Bool = false
  /// External session requests — the App Intent, the URL scheme. Observed here
  /// because this view exists for the whole life of the UI, so no request can land
  /// while nobody is looking.
  @State private var launchRouter = SessionLaunchRouter.shared
  @State private var showLaunchedSession = false

  init(wearables: WearablesInterface, viewModel: WearablesViewModel) {
    self.wearables = wearables
    self.viewModel = viewModel
  }

  var body: some View {
    Group {
      // Voice-first pivot: the app is a standalone phone app, so the tab tree is
      // always reachable. Glasses registration is no longer an entry requirement —
      // HomeScreenView and the DAT registration flow remain only until the legacy
      // glasses code is deleted.
      RootTabView(wearables: wearables, wearablesVM: viewModel)
    }
    .fullScreenCover(isPresented: .constant(!hasCompletedOnboarding)) {
      OnboardingCoordinatorView(wearablesViewModel: viewModel) {
        hasCompletedOnboarding = true
      }
      .interactiveDismissDisabled(true)
    }
    // Sessions requested from outside the view tree: Action Button, Shortcuts,
    // Spotlight, the URL scheme. No book binding on this path — speed of entry is
    // the point, and the session links to a book at the end if it needs one.
    .fullScreenCover(isPresented: $showLaunchedSession) {
      VoiceSessionView(book: nil)
    }
    .onChange(of: launchRouter.pendingLaunch) { _, pending in
      guard pending else { return }
      presentLaunchedSessionIfReady()
    }
    // A cold launch from the intent sets the flag before this view exists, so the
    // change never fires — check once on appearance too.
    .task {
      presentLaunchedSessionIfReady()
    }
    .onOpenURL { url in
      launchRouter.handle(url)
    }
  }

  private func presentLaunchedSessionIfReady() {
    guard launchRouter.pendingLaunch, hasCompletedOnboarding else { return }
    launchRouter.consume()
    showLaunchedSession = true
  }
}
