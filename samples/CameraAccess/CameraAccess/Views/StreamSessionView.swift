/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionView.swift
//
//

import MWDATCore
import SwiftUI

struct StreamSessionView: View {
  let wearables: WearablesInterface
  @ObservedObject private var wearablesViewModel: WearablesViewModel
  @StateObject private var viewModel: StreamSessionViewModel
  @Environment(\.dismiss) private var dismiss
  let book: Book?
  let cameraMode: CameraMode

  init(wearables: WearablesInterface, wearablesVM: WearablesViewModel, cameraMode: CameraMode = .glasses, book: Book? = nil) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
    self.cameraMode = cameraMode
    self.book = book
    switch cameraMode {
    case .glasses:
      self._viewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables, book: book))
    case .phoneCamera:
      self._viewModel = StateObject(wrappedValue: StreamSessionViewModel(phoneCamera: true, book: book))
    }
  }

  var body: some View {
    ZStack {
      if viewModel.isStreaming {
        StreamView(viewModel: viewModel, wearablesVM: wearablesViewModel)
      } else {
        NonStreamView(viewModel: viewModel, wearablesVM: wearablesViewModel, cameraMode: cameraMode)
      }
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") {
        viewModel.dismissError()
      }
    } message: {
      Text(viewModel.errorMessage)
    }
    // When a session ends with an unidentified cover, present the manual-link
    // sheet before the fullScreenCover's dismiss can fire. The user can pick
    // an existing library book, search Open Library, or skip.
    .sheet(
      isPresented: Binding(
        get: { viewModel.pendingOrphanSession != nil },
        set: { if !$0 { viewModel.pendingOrphanSession = nil } }
      )
    ) {
      if let session = viewModel.pendingOrphanSession {
        OrphanSessionLinkView(session: session) {
          viewModel.pendingOrphanSession = nil
        }
      }
    }
  }
}
