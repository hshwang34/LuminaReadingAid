/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionViewModel.swift
//
// Core view model demonstrating video streaming from Meta wearable devices using the DAT SDK.
// This class showcases the key streaming patterns: device selection, session management,
// video frame handling, photo capture, and error handling.
//

import Combine
import ImageIO
import MWDATCamera
import MWDATCore
import SwiftData
import SwiftUI

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var hasActiveDevice: Bool = false
  @Published var handTrackingResult: HandTrackingResult = .empty
  @Published var isHandTrackingEnabled: Bool = true
  @Published var lastCapturedWord: String?
  /// The cropped image from the most recent OCR scan, shown as a live preview on the stream view.
  @Published var currentOCRCrop: UIImage?
  /// OCR search region in Vision normalized coords (0–1, bottom-left origin). Shown as debug overlay.
  @Published var ocrDebugRect: CGRect?

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false
  // The core DAT SDK StreamSession - handles all streaming operations
  private var streamSession: StreamSession
  // Listener tokens are used to manage DAT SDK event subscriptions
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceMonitorTask: Task<Void, Never>?
  // Hand tracking
  private let handPoseService = HandPoseService()
  private var handTrackingCancellable: AnyCancellable?
  // Word capture
  private let wordCaptureService = WordCaptureService()
  private var hasConsumedCurrentTrigger = false
  /// Stores the fingertip position from the moment a photo capture is triggered for OCR.
  /// nil means the next incoming photo is a manual user capture.
  private var pendingOCRTip: CGPoint?
  private var modelContext: ModelContext { AppContainer.shared.mainContext }

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    // Let the SDK auto-select from available devices
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.high,
      frameRate: 15)
    streamSession = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)

    // Monitor device availability
    deviceMonitorTask = Task { @MainActor in
      for await device in deviceSelector.activeDeviceStream() {
        self.hasActiveDevice = device != nil
      }
    }

    // Subscribe to session state changes using the DAT SDK listener pattern
    // State changes tell us when streaming starts, stops, or encounters issues
    stateListenerToken = streamSession.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        self?.updateStatusFromState(state)
      }
    }

    // Subscribe to video frames from the device camera
    // Each VideoFrame contains the raw camera data that we convert to UIImage
    videoFrameListenerToken = streamSession.videoFramePublisher.listen { [weak self] videoFrame in
      // Process hand tracking on the SDK callback thread (before main actor hop)
      self?.handPoseService.processFrame(videoFrame.sampleBuffer)

      Task { @MainActor [weak self] in
        guard let self else { return }

        if let image = videoFrame.makeUIImage() {
          self.currentVideoFrame = image
          if !self.hasReceivedFirstFrame {
            self.hasReceivedFirstFrame = true
          }
        }
      }
    }

    // Subscribe to streaming errors
    // Errors include device disconnection, streaming failures, etc.
    errorListenerToken = streamSession.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let newErrorMessage = formatStreamingError(error)
        if newErrorMessage != self.errorMessage {
          showError(newErrorMessage)
        }
      }
    }

    updateStatusFromState(streamSession.state)

    // Subscribe to photo capture events
    // PhotoData contains the captured image in the requested format (JPEG/HEIC)
    photoDataListenerToken = streamSession.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard let uiImage = UIImage(data: photoData.data) else { return }

        if let pendingTip = self.pendingOCRTip {
          // Photo was triggered for OCR — run OCR, don't show preview sheet
          self.pendingOCRTip = nil
          await self.processOCRPhoto(image: uiImage, tipNormalized: pendingTip)
        } else {
          // Manual camera button — show preview as before
          self.capturedPhoto = uiImage
          self.showPhotoPreview = true
        }
      }
    }

    // Subscribe to hand tracking results and forward to published property
    handTrackingCancellable = handPoseService.resultPublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] result in
        guard let self else { return }
        self.handTrackingResult = result

        // Reset debounce when pinch is released
        if case .triggered = result.pinchState { } else {
          self.hasConsumedCurrentTrigger = false
        }

        // Fire OCR once per pinch event
        if case .triggered = result.pinchState,
           result.isValidPose,
           !self.hasConsumedCurrentTrigger,
           let tipNorm = result.landmarks?.point(for: .indexTip) {
          self.hasConsumedCurrentTrigger = true
          self.triggerOCRCapture(tipNormalized: tipNorm)
        }
      }
  }

  func handleStartStreaming() async {
    let permission = Permission.camera
    do {
      let status = try await wearables.checkPermissionStatus(permission)
      if status == .granted {
        await startSession()
        return
      }
      let requestStatus = try await wearables.requestPermission(permission)
      if requestStatus == .granted {
        await startSession()
        return
      }
      showError("Permission denied")
    } catch {
      showError("Permission error: \(error.description)")
    }
  }

  func startSession() async {
    await streamSession.start()
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  func stopSession() async {
    pendingOCRTip = nil
    ocrDebugRect = nil
    handPoseService.reset()
    await streamSession.stop()
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func capturePhoto() {
    streamSession.capturePhoto(format: .jpeg)
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func triggerOCRCapture(tipNormalized: CGPoint) {
    let w: CGFloat = 0.12, h: CGFloat = 0.05
    let centerY = tipNormalized.y + 0.02
    let cropRect = CGRect(
      x: max(0, tipNormalized.x - w / 2),
      y: max(0, centerY - h / 2),
      width: w, height: h
    )
    ocrDebugRect = cropRect
    pendingOCRTip = tipNormalized
    NSLog("[OCR] photo capture triggered — tip=(%.3f, %.3f)", tipNormalized.x, tipNormalized.y)
    streamSession.capturePhoto(format: .jpeg)
  }

  private func processOCRPhoto(image: UIImage, tipNormalized: CGPoint) async {
    // Re-detect the fingertip in the photo's own coordinate space.
    // The photo (portrait) and video stream (landscape) have different aspect ratios,
    // so video-space coords cannot be used as regionOfInterest on the photo directly.
    // We also pass EXIF orientation so Vision normalizes into the display-oriented space.
    guard let cgImage = image.cgImage else {
      NSLog("[OCR] photo has no cgImage, aborting")
      ocrDebugRect = nil
      return
    }
    let orientation = CGImagePropertyOrientation(image.imageOrientation)
    NSLog("[OCR] photo UIImage size=%.0fx%.0f cgImage=%dx%d orientation=%d(raw)",
          image.size.width, image.size.height,
          cgImage.width, cgImage.height,
          orientation.rawValue)

    let photoTip = await Task.detached(priority: .userInitiated) { [handPoseService] in
      handPoseService.detectPointingTip(in: cgImage, orientation: orientation)
    }.value

    guard let photoTip else {
      NSLog("[OCR] finger gone or invalid pose in photo — aborting")
      ocrDebugRect = nil
      return
    }

    // Build a fresh crop rect from the photo-space tip position
    let w: CGFloat = 0.12, h: CGFloat = 0.05
    let centerY = photoTip.y + 0.02
    let cropRect = CGRect(
      x: max(0, photoTip.x - w / 2),
      y: max(0, centerY - h / 2),
      width: w, height: h
    )

    NSLog("[OCR] processing photo — video tip=(%.3f,%.3f) photo tip=(%.3f,%.3f) size=%dx%d",
          tipNormalized.x, tipNormalized.y,
          photoTip.x, photoTip.y,
          Int(image.size.width), Int(image.size.height))

    let service = wordCaptureService
    let result = await Task.detached(priority: .userInitiated) {
      await service.recognizeWord(in: image, cropRect: cropRect)
    }.value
    NSLog("[OCR] result: \"%@\"", result.text)

    // Show the original (non-processed) crop as the live stream preview
    withAnimation(.spring(duration: 0.25)) {
      currentOCRCrop = result.originalCrop
    }

    // Always save to review list — even empty results, so every crop is visible.
    let imageData = result.originalCrop.flatMap { $0.jpegData(compressionQuality: 0.85) }
    let preprocessedImageData = result.preprocessedCrop.flatMap { $0.jpegData(compressionQuality: 0.85) }
    let captured = CapturedWord(text: result.text, imageData: imageData, preprocessedImageData: preprocessedImageData)
    modelContext.insert(captured)
    try? modelContext.save()

    ocrDebugRect = nil

    guard !result.text.isEmpty else {
      try? await Task.sleep(for: .seconds(2))
      withAnimation(.easeOut(duration: 0.3)) { currentOCRCrop = nil }
      return
    }

    withAnimation(.spring(duration: 0.3)) { lastCapturedWord = result.text }
    try? await Task.sleep(for: .seconds(2))
    withAnimation(.easeOut(duration: 0.3)) {
      if lastCapturedWord == result.text { lastCapturedWord = nil }
      currentOCRCrop = nil
    }
  }

  private func updateStatusFromState(_ state: StreamSessionState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
      handPoseService.reset()
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
    }
  }

  private func formatStreamingError(_ error: StreamSessionError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .audioStreamingError:
      return "Audio streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "The hinges on the glasses were closed. Please open the hinges and try again."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }
}

// MARK: - CGImagePropertyOrientation from UIImage.Orientation

extension CGImagePropertyOrientation {
  /// Converts UIImage.Orientation (used by UIKit) to the EXIF-based
  /// CGImagePropertyOrientation expected by VNImageRequestHandler.
  init(_ uiOrientation: UIImage.Orientation) {
    switch uiOrientation {
    case .up:            self = .up
    case .upMirrored:    self = .upMirrored
    case .down:          self = .down
    case .downMirrored:  self = .downMirrored
    case .left:          self = .left
    case .leftMirrored:  self = .leftMirrored
    case .right:         self = .right
    case .rightMirrored: self = .rightMirrored
    @unknown default:    self = .up
    }
  }
}
