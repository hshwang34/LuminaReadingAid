/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamView.swift
//
// Main UI for video streaming from Meta wearable devices using the DAT SDK.
// This view demonstrates the complete streaming API: video streaming with real-time display, photo capture,
// and error handling.
//

import MWDATCore
import SwiftData
import SwiftUI

struct StreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var wearablesVM: WearablesViewModel

  var body: some View {
    ZStack {
      // Black background for letterboxing/pillarboxing
      Color.black
        .edgesIgnoringSafeArea(.all)

      // Video backdrop
      if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          ZStack {
            Image(uiImage: videoFrame)
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(width: geometry.size.width, height: geometry.size.height)
              .clipped()

            if viewModel.isHandTrackingEnabled {
              HandOverlayView(
                trackingResult: viewModel.handTrackingResult,
                imageSize: videoFrame.size,
                viewSize: geometry.size
              )
              .frame(width: geometry.size.width, height: geometry.size.height)
            }

            // OCR debug region
            if let rect = viewModel.ocrDebugRect {
              OCRDebugOverlay(
                visionRect: rect,
                imageSize: videoFrame.size,
                viewSize: geometry.size
              )
              .frame(width: geometry.size.width, height: geometry.size.height)
              .allowsHitTesting(false)
            }

            // Word capture toast
            if let word = viewModel.lastCapturedWord {
              VStack {
                Text(word)
                  .font(.system(size: 36, weight: .bold, design: .rounded))
                  .foregroundColor(.white)
                  .padding(.horizontal, 28)
                  .padding(.vertical, 16)
                  .background(.black.opacity(0.75))
                  .clipShape(RoundedRectangle(cornerRadius: 20))
                Spacer()
              }
              .padding(.top, 72)
              .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
          }
        }
        .edgesIgnoringSafeArea(.all)
        .animation(.spring(duration: 0.3), value: viewModel.lastCapturedWord)
      } else {
        ProgressView()
          .scaleEffect(1.5)
          .foregroundColor(.white)
      }

      // OCR crop preview — appears top-right whenever OCR fires
      if let crop = viewModel.currentOCRCrop {
        VStack {
          HStack {
            Spacer()
            Image(uiImage: crop)
              .resizable()
              .aspectRatio(contentMode: .fit)
              .frame(width: 160, height: 80)
              .clipShape(RoundedRectangle(cornerRadius: 10))
              .overlay(
                RoundedRectangle(cornerRadius: 10)
                  .strokeBorder(Color.yellow, lineWidth: 1.5)
              )
              .shadow(radius: 6)
              .padding(.top, 56)
              .padding(.trailing, 16)
          }
          Spacer()
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
        .allowsHitTesting(false)
      }

      // Bottom controls layer

      VStack {
        Spacer()
        ControlsView(viewModel: viewModel)
      }
      .padding(.all, 24)
    }
    .animation(.spring(duration: 0.25), value: viewModel.currentOCRCrop != nil)
    .onDisappear {
      Task {
        if viewModel.streamingStatus != .stopped {
          await viewModel.stopSession()
        }
      }
    }
    // Show captured photos from DAT SDK in a preview sheet
    .sheet(isPresented: $viewModel.showPhotoPreview) {
      if let photo = viewModel.capturedPhoto {
        PhotoPreviewView(
          photo: photo,
          onDismiss: {
            viewModel.dismissPhotoPreview()
          }
        )
      }
    }
  }
}

// MARK: - OCR Debug Overlay

struct OCRDebugOverlay: View {
  let visionRect: CGRect   // Vision normalized coords (0–1, bottom-left origin)
  let imageSize: CGSize
  let viewSize: CGSize

  var body: some View {
    Canvas { context, _ in
      let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
      let scaledW = imageSize.width * scale
      let scaledH = imageSize.height * scale
      let offX = (scaledW - viewSize.width) / 2
      let offY = (scaledH - viewSize.height) / 2

      // Convert Vision rect corners to view coords
      let left   = visionRect.minX * scaledW - offX
      let right  = visionRect.maxX * scaledW - offX
      let top    = (1.0 - visionRect.maxY) * scaledH - offY
      let bottom = (1.0 - visionRect.minY) * scaledH - offY

      let viewRect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
      var path = Path(viewRect)
      context.stroke(path, with: .color(.yellow), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))

      // Cross-hair at rect center
      let cx = (left + right) / 2
      let cy = (top + bottom) / 2
      var cross = Path()
      cross.move(to: CGPoint(x: cx - 8, y: cy)); cross.addLine(to: CGPoint(x: cx + 8, y: cy))
      cross.move(to: CGPoint(x: cx, y: cy - 8)); cross.addLine(to: CGPoint(x: cx, y: cy + 8))
      context.stroke(cross, with: .color(.yellow), lineWidth: 2)
    }
  }
}

// Extracted controls for clarity
struct ControlsView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @State private var showCapturedWords = false

  var body: some View {
    // Controls row
    HStack(spacing: 8) {
      CustomButton(
        title: "Stop streaming",
        style: .destructive,
        isDisabled: false
      ) {
        Task {
          await viewModel.stopSession()
        }
      }

      // Photo button
      CircleButton(icon: "camera.fill", text: nil) {
        viewModel.capturePhoto()
      }

      // Review captured words
      CircleButton(icon: "list.bullet", text: nil) {
        showCapturedWords = true
      }
    }
    .sheet(isPresented: $showCapturedWords) {
      CapturedWordsView()
        .modelContainer(AppContainer.shared)
    }
  }
}
