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
        if let uiImage = UIImage(data: photoData.data) {
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

        // Reset debounce whenever the trigger is no longer active
        if case .triggered = result.stillnessState { } else {
          self.hasConsumedCurrentTrigger = false
        }

        // Fire OCR once per stillness event
        if case .triggered = result.stillnessState,
           result.isValidPose,
           !self.hasConsumedCurrentTrigger,
           let frame = self.currentVideoFrame,
           let tipNorm = result.landmarks?.point(for: .indexTip) {
          self.hasConsumedCurrentTrigger = true
          Task { await self.captureWord(frame: frame, tipNormalized: tipNorm) }
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

  private func captureWord(frame: UIImage, tipNormalized: CGPoint) async {
    NSLog("[OCR] captureWord fired — tip=(%.3f, %.3f)", tipNormalized.x, tipNormalized.y)
    let service = wordCaptureService
    let word = await Task.detached(priority: .userInitiated) {
      await service.recognizeWord(in: frame, tipNormalized: tipNormalized)
    }.value
    NSLog("[OCR] result: %@", word ?? "nil")

    guard let word, !word.isEmpty else { return }

    let captured = CapturedWord(text: word)
    modelContext.insert(captured)
    try? modelContext.save()

    withAnimation(.spring(duration: 0.3)) { lastCapturedWord = word }
    try? await Task.sleep(for: .seconds(2))
    withAnimation(.easeOut(duration: 0.3)) {
      if lastCapturedWord == word { lastCapturedWord = nil }
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
