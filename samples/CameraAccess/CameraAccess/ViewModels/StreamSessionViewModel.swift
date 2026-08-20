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
import CoreMedia
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

/// User-visible state of the page-number detection pipeline. Drives the
/// `PageScanStatusChip` overlay on StreamView so the user gets feedback about
/// what the detector is doing without needing to read debug logs.
enum PageScanStatus: Equatable {
  /// Detector is dormant — no active book, or waiting for the first frame.
  case idle
  /// Actively scanning top/bottom margin strips, hunting for a stable page-
  /// number ROI. The UI shows a spinner and "Searching for page number…".
  case searching
  /// The per-book ROI has just been committed. The UI briefly shows "Page
  /// number located" with a checkmark, then auto-hides after a few seconds.
  case located
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  /// Cached video frame size — updated only when dimensions actually change, so views
  /// that depend on size (like HandOverlayView) don't redraw on every frame.
  @Published var videoFrameSize: CGSize = .zero
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
  /// OCR search region as an oriented (tilt-aware) crop, shown as the yellow debug overlay.
  @Published var ocrDebugCrop: OrientedCrop?
  // Highlight gesture
  @Published var highlightPhase: HighlightGesturePhase = .idle
  @Published var currentUnderlineSelection: UnderlineSelection?
  @Published var startMarkerCamera: CGPoint?
  /// Live-computed full-column OCR strip(s) from the active highlight trail, for overlay + capture.
  @Published var highlightStripSelection: ColumnStripSelection?
  @Published var lastCapturedPassage: String?
  /// Debug: the current document quadrilateral (drawn as cyan outline on overlay).
  @Published var debugTrackingQuad: PageTrackingService.DocumentQuad?
  /// Currently committed reading page, after debouncing. Shown as a chip on the stream view.
  @Published var currentPage: Int?
  /// Reading pace averaged over the last few minutes of committed page transitions.
  @Published var pagesPerMinute: Double?
  /// Set in `stopSession()` when the session ended without a bound book AND the
  /// identification attempt explicitly failed. Drives the `OrphanSessionLinkView`
  /// sheet in StreamSessionView, which lets the user either pick an existing
  /// library book or search Open Library to register a new one.
  @Published var pendingOrphanSession: ReadingSession?
  /// The latest raw (pre-debounce) page-number values read by the detector, one per
  /// visible page. Shown on the debug overlay so you can visually confirm the scan is
  /// working before the debouncer has committed anything.
  @Published var lastRawPageValues: [Int] = []
  /// Oriented crops the detector would OCR for the current frame. Drawn as dashed
  /// rectangles on the stream view so the user can see the margin strips (learning
  /// mode) or the tight ROI box (locked mode).
  @Published var pageScanDebugCrops: [OrientedCrop] = []
  /// True when the active book already has a learned ROI — used to label the debug
  /// overlay as "learning" vs "locked".
  @Published var pageScanIsLocked: Bool = false
  /// User-visible status of the page-number detector. Drives the status pill that
  /// mirrors the book-identification overlay: `.searching` while learning the ROI,
  /// `.located` briefly after it commits (auto-hides), `.idle` otherwise.
  @Published var pageScanStatus: PageScanStatus = .idle

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false

  let cameraMode: CameraMode

  // DAT SDK glasses path (nil when phoneCamera)
  private var streamSession: StreamSession?
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private var wearables: WearablesInterface?
  private var deviceSelector: AutoDeviceSelector?
  private var deviceMonitorTask: Task<Void, Never>?

  // Phone camera path (nil when glasses)
  private var phoneCameraService: PhoneCameraService?
  // Hand tracking
  private let handPoseService = HandPoseService()
  private var handTrackingCancellable: AnyCancellable?
  /// Subscription that listens for the first `.matched` phase transition and
  /// binds the matched book to this session. Cover-first path only — when the
  /// session was pre-locked from Library, the subscription still fires but
  /// `bindSession` short-circuits because `activeBook` is already set.
  private var bookIDCancellable: AnyCancellable?
  // Page tracking (VNTrackObjectRequest, only active during highlighting)
  private let pageTrackingService = PageTrackingService()
  // Book cover identification pipeline — passively watches document segmentation
  // output and fires when the user holds up a book cover.
  private let coverDetector = CoverDetector()
  let bookIdentification: BookIdentificationService = BookIdentificationService(
    modelContext: AppContainer.shared.mainContext
  )
  /// Thread-safe bridge for data written on the video frame background thread
  /// and read on the main thread. Isolated from @MainActor.
  private let flowBridge = FlowBridge()
  // Highlight gesture
  private let highlightTracker = HighlightGestureTracker()
  private let passageExtractionService = PassageExtractionService()
  /// Pending passage extraction state — oriented strip crops waiting for photo arrival.
  private var pendingPassageCrops: [OrientedCrop]?
  /// Start column for the current highlight gesture, locked when .highlighting begins.
  private var highlightStartColumn: PageColumn?
  // HEVC decoding
  private let hevcDecoder = HEVCDecoder()
  // Word capture
  private let wordCaptureService = WordCaptureService()
  // Page number detection + progress tracking
  private let pageNumberDetector = PageNumberDetector()
  private let pageProgressTracker = PageProgressTracker()
  private let pageROILearner = PageROILearner()
  private var pageScanLoopTask: Task<Void, Never>?
  private var isPageScanRunning = false
  /// Gap between scans while the ROI is still being learned. Deliberately tiny —
  /// OCR dominates the iteration time anyway, so this mostly just yields the
  /// actor so other main-thread work can run. Result: roughly OCR-bound cadence
  /// (~5–10 scans/sec) until the ROI converges.
  private let pageScanLearningInterval: TimeInterval = 0.05
  /// Gap between scans once the per-book ROI is locked. Page numbers don't
  /// change between frames so the 30s cadence is purely a battery budget.
  private let pageScanLockedInterval: TimeInterval = 30
  /// Consecutive locked-mode misses before we clear the ROI and restart learning.
  private let lockedROIMissLimit = 10
  /// Auto-hides the "page number located" pill a few seconds after the ROI commits.
  private var pageScanStatusHideTask: Task<Void, Never>?
  /// Coordinates the post-capture spoken-definition flow: LLM → TTS → mic listen
  /// with VAD → follow-up LLM chat → TTS loop. Starts after each word capture,
  /// cancels on stream stop.
  let wordConversation = WordConversationCoordinator()
  private var hasConsumedCurrentTrigger = false
  /// Stores the fingertip position from the moment a photo capture is triggered for OCR.
  /// nil means the next incoming photo is a manual user capture.
  private var pendingOCRTip: CGPoint?
  /// Pending word-in-context capture: fingertip (in camera coords) + oriented context crop.
  private var pendingWordCaptureTip: CGPoint?
  private var pendingWordCaptureCrop: OrientedCrop?
  private var modelContext: ModelContext { AppContainer.shared.mainContext }

  // Book context for the current reading session
  private(set) var activeBook: Book?
  private(set) var activeSession: ReadingSession?

  init(wearables: WearablesInterface, book: Book? = nil) {
    self.cameraMode = .glasses
    self.wearables = wearables
    self.activeBook = book
    // Pre-lock the cover pipeline if the user picked a book from Library before
    // starting — the whole identification path is skipped for this session and
    // `phase` starts at `.matched(book)`.
    if let book {
      bookIdentification.lock(to: book)
    }
    // Let the SDK auto-select from available devices
    let selector = AutoDeviceSelector(wearables: wearables)
    self.deviceSelector = selector
    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.high,
      frameRate: 15)
    let session = StreamSession(streamSessionConfig: config, deviceSelector: selector)
    self.streamSession = session

    // Monitor device availability
    deviceMonitorTask = Task { @MainActor in
      for await deviceId in selector.activeDeviceStream() {
        self.hasActiveDevice = deviceId != nil
      }
    }

    // Subscribe to session state changes using the DAT SDK listener pattern
    stateListenerToken = session.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        self?.updateStatusFromState(state)
      }
    }

    // Subscribe to video frames from the device camera
    let handPose = handPoseService
    let pageTracking = pageTrackingService
    let decoder = hevcDecoder
    let detector = coverDetector
    let bookID = bookIdentification
    var frameCount = 0
    videoFrameListenerToken = session.videoFramePublisher.listen { [weak self] videoFrame in
      guard let pixelBuffer = CMSampleBufferGetImageBuffer(videoFrame.sampleBuffer) else { return }
      handPose.processFrame(pixelBuffer)
      let trackResult = pageTracking.processFrame(pixelBuffer)
      self?.flowBridge.store(result: trackResult, pixelBuffer: pixelBuffer)

      // Cover identification: suppressed while any capture gesture is in flight.
      let gestureActive = self?.flowBridge.isGestureActive() ?? false
      #if DEBUG
      frameCount += 1
      if frameCount % 30 == 0 {
        NSLog("[CoverPipe-Glasses] frame #%d track=%@ confidence=%.2f gesture=%@ locked=%@",
              frameCount,
              trackResult == nil ? "nil" : "yes",
              trackResult?.confidence ?? -1,
              gestureActive ? "active" : "idle",
              bookID.isLockedSnapshot() ? "yes" : "no")
      }
      #endif
      // Session is locked to a book → skip the entire cover pipeline. This is
      // the "one session, one book" invariant: once matched, never try again.
      if !bookID.isLockedSnapshot() {
        if let candidate = detector.ingest(
          trackingResult: trackResult,
          pixelBuffer: pixelBuffer,
          isGestureActive: gestureActive,
          now: CACurrentMediaTime()
        ) {
          #if DEBUG
          NSLog("[CoverPipe-Glasses] 🎯 candidate emitted → submitting to BookIdentificationService")
          #endif
          Task { @MainActor in
            bookID.submit(candidate: candidate)
          }
        }
      }

      guard let image = decoder.makeImage(from: pixelBuffer) else { return }
      let debugQuad = trackResult?.quad
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.currentVideoFrame = image
        self.debugTrackingQuad = debugQuad
        if image.size != self.videoFrameSize { self.videoFrameSize = image.size }
        if !self.hasReceivedFirstFrame { self.hasReceivedFirstFrame = true }
      }
    }

    // Subscribe to streaming errors
    errorListenerToken = session.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let newErrorMessage = formatStreamingError(error)
        if newErrorMessage != self.errorMessage { showError(newErrorMessage) }
      }
    }

    updateStatusFromState(session.state)

    // Subscribe to photo capture events
    photoDataListenerToken = session.photoDataPublisher.listen { [weak self] photoData in
      let uiImage = UIImage(data: photoData.data)
      Task { @MainActor [weak self] in
        guard let self, let uiImage else { return }
        self.handlePhotoData(uiImage)
      }
    }

    setupHandTrackingSubscription()
    setupBookIdentificationSubscription()
    startPageScanLoop()

    // Invalidate HEVC decoder when app backgrounds — hardware decoder is a scarce resource.
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.hevcDecoder.invalidate()
    }
  }

  // MARK: - Phone Camera Init

  init(phoneCamera: Bool = true, book: Book? = nil) {
    self.cameraMode = .phoneCamera
    self.activeBook = book
    self.hasActiveDevice = true  // phone camera is always available
    // Same pre-lock as the glasses init — if the user pre-picked a book, cover
    // identification never runs for this session.
    if let book {
      bookIdentification.lock(to: book)
    }

    let service = PhoneCameraService()
    self.phoneCameraService = service

    let handPose = handPoseService
    let pageTracking = pageTrackingService
    let decoder = hevcDecoder

    let detector = coverDetector
    let bookID = bookIdentification
    var frameCount = 0
    service.onFrame = { [weak self] pixelBuffer in
      handPose.processFrame(pixelBuffer)
      let trackResult = pageTracking.processFrame(pixelBuffer)
      self?.flowBridge.store(result: trackResult, pixelBuffer: pixelBuffer)

      let gestureActive = self?.flowBridge.isGestureActive() ?? false
      #if DEBUG
      frameCount += 1
      if frameCount % 30 == 0 {
        NSLog("[CoverPipe-Phone] frame #%d track=%@ confidence=%.2f gesture=%@ locked=%@",
              frameCount,
              trackResult == nil ? "nil" : "yes",
              trackResult?.confidence ?? -1,
              gestureActive ? "active" : "idle",
              bookID.isLockedSnapshot() ? "yes" : "no")
      }
      #endif
      if !bookID.isLockedSnapshot() {
        if let candidate = detector.ingest(
          trackingResult: trackResult,
          pixelBuffer: pixelBuffer,
          isGestureActive: gestureActive,
          now: CACurrentMediaTime()
        ) {
          #if DEBUG
          NSLog("[CoverPipe-Phone] 🎯 candidate emitted → submitting to BookIdentificationService")
          #endif
          Task { @MainActor in
            bookID.submit(candidate: candidate)
          }
        }
      }

      guard let image = decoder.makeImage(from: pixelBuffer) else { return }
      let debugQuad = trackResult?.quad
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.currentVideoFrame = image
        self.debugTrackingQuad = debugQuad
        if image.size != self.videoFrameSize { self.videoFrameSize = image.size }
        if !self.hasReceivedFirstFrame { self.hasReceivedFirstFrame = true }
      }
    }

    service.onPhoto = { [weak self] data in
      let uiImage = UIImage(data: data)
      Task { @MainActor [weak self] in
        guard let self, let uiImage else { return }
        self.handlePhotoData(uiImage)
      }
    }

    service.onError = { [weak self] message in
      Task { @MainActor [weak self] in
        self?.showError(message)
      }
    }

    setupHandTrackingSubscription()
    setupBookIdentificationSubscription()
    startPageScanLoop()
  }

  // MARK: - Shared Setup

  /// Subscribes to `BookIdentificationService.$phase`. The first time a cover
  /// match arrives for a session that was *not* pre-bound from Library, this
  /// binds the matched book to the session and inserts the ReadingSession into
  /// the model context — the critical late-binding step for the cover-first flow.
  private func setupBookIdentificationSubscription() {
    bookIDCancellable = bookIdentification.$phase
      .receive(on: DispatchQueue.main)
      .sink { [weak self] phase in
        guard let self else { return }
        switch phase {
        case .matched(let book, _):
          if self.activeBook == nil { self.bindSession(to: book) }
        case .failed:
          if let failure = self.bookIdentification.lastFailedAttempt {
            self.recordFailedCoverAttempt(failure)
          }
        case .idle, .identifying, .needsDisambiguation:
          break
        }
      }
  }

  /// Late session binding — swap `activeBook` to the cover-matched book and
  /// attach it to the ReadingSession we already created in `startSession()`.
  /// Safe to call once per session; subsequent `.matched` events are filtered
  /// out by the `activeBook == nil` guard in the subscription.
  private func bindSession(to book: Book) {
    self.activeBook = book
    if let session = activeSession, session.book == nil {
      session.book = book
      try? modelContext.save()
    } else if activeSession == nil {
      // Defensive: identification somehow beat startSession() to creating a
      // container. Build one now so captures have somewhere to live.
      let session = ReadingSession(book: book)
      modelContext.insert(session)
      try? modelContext.save()
      activeSession = session
    }
    #if DEBUG
    NSLog("[BookID] session bound to \"%@\"", book.title)
    #endif
  }

  /// Persist a failed cover attempt onto the active reading session. Computes
  /// the pHash here (the service doesn't know about persistence) and caches
  /// the canonical cover image as JPEG so the session-end orphan sheet can
  /// display it back to the user.
  private func recordFailedCoverAttempt(_ failure: FailedCoverAttempt) {
    guard let session = activeSession else { return }
    session.identificationFailed = true
    session.coverAttemptOCRTitle = failure.ocrTitle.isEmpty ? nil : failure.ocrTitle
    session.coverAttemptOCRAuthor = failure.ocrAuthor.isEmpty ? nil : failure.ocrAuthor
    if let cg = failure.canonicalCover {
      session.coverAttemptImageData = jpegData(fromCGImage: cg)
      session.coverAttemptPHashHex = PerceptualHash.hash(cgImage: cg)
    }
    try? modelContext.save()
    #if DEBUG
    NSLog("[BookID] recorded failed cover attempt — reason=\(failure.reason) pHash=\(session.coverAttemptPHashHex ?? "nil")")
    #endif
  }

  private func setupHandTrackingSubscription() {
    handTrackingCancellable = handPoseService.resultPublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] result in
        guard let self else { return }
        self.handTrackingResult = result
        // debugTrackingQuad is updated every frame from the video listener — not here

        // Compute book-relative fingertip for trail accumulation
        let bookRelativePoint: CGPoint? = {
          guard let tip = result.landmarks?.point(for: .indexTip) else { return nil }
          return self.pageTrackingService.toBookRelative(tip)
        }()
        let bookAnchor = self.pageTrackingService.currentAnchor()

        let previousPhase = self.highlightPhase
        let phase = self.highlightTracker.update(
          pinchDistance: result.pinchDistance,
          fingerTipCamera: result.landmarks?.point(for: .indexTip),
          bookRelativePoint: bookRelativePoint,
          anchor: bookAnchor,
          timestamp: result.timestamp
        )
        self.highlightPhase = phase
        self.currentUnderlineSelection = self.highlightTracker.underlineSelection
        self.startMarkerCamera = self.highlightTracker.startMarkerCamera
        self.refreshGestureActiveFlag()

        // Lock the start column the frame highlighting begins.
        if previousPhase != .highlighting, phase == .highlighting {
          if let sel = self.highlightTracker.underlineSelection,
             let firstPoint = sel.lines.first?.points.first,
             let quad = self.debugTrackingQuad {
            let layout = PageColumnLayout(
              topLeft: quad.topLeft,
              topRight: quad.topRight,
              bottomLeft: quad.bottomLeft,
              bottomRight: quad.bottomRight,
              axes: self.pageTrackingService.currentBookAxes()
            )
            // Classify in book-axis space: x < 0 means the left page.
            let firstCamera = CGPoint(x: sel.anchor.x + firstPoint.x, y: sel.anchor.y + firstPoint.y)
            let firstBook = layout.toBookAxisSpace(firstCamera)
            self.highlightStartColumn = firstBook.x < 0 ? .left : .right
          }
        }

        // Live strip computation — runs every hand-tracking tick during highlight/completed.
        if (phase == .highlighting || phase == .completed),
           let sel = self.highlightTracker.underlineSelection,
           let quad = self.debugTrackingQuad,
           let startCol = self.highlightStartColumn {
          let layout = PageColumnLayout(
            topLeft: quad.topLeft,
            topRight: quad.topRight,
            bottomLeft: quad.bottomLeft,
            bottomRight: quad.bottomRight,
            axes: self.pageTrackingService.currentBookAxes()
          )
          self.highlightStripSelection = sel.columnStrips(layout: layout, startColumn: startCol)
        } else if phase == .idle {
          self.highlightStripSelection = nil
          self.highlightStartColumn = nil
        }

        // Quick pinch release (< 0.3s) — trigger word capture
        if case .pinchStarted = previousPhase, phase == .idle {
          if let tip = result.landmarks?.point(for: .indexTip) {
            self.triggerWordCapture(fingerTip: tip)
          }
        }

        if phase == .completed {
          if let crops = self.highlightStripSelection?.crops, !crops.isEmpty {
            self.triggerPassageExtraction(crops: crops)
          }
          self.highlightTracker.reset()
        }
      }
  }

  /// Triggers word-in-context capture using the page-aware crop region.
  /// Falls back to the legacy fixed crop if no document is detected.
  private func triggerWordCapture(fingerTip: CGPoint) {
    // The index tip joint sits at the middle of the last finger segment, but the user
    // points with the actual tip — slightly above the joint in Vision coords.
    // Lift the fingertip up by this offset to compensate.
    // Also nudge slightly left, since the joint indicator visually sits to the right of
    // where the user is actually pointing.
    let fingertipYOffset: CGFloat = 0.01
    let fingertipXOffset: CGFloat = -0.003
    let liftedTip = CGPoint(x: fingerTip.x + fingertipXOffset, y: fingerTip.y + fingertipYOffset)

    if let crop = pageTrackingService.contextCropRegion(fingerTip: liftedTip) {
      #if DEBUG
      NSLog("[WordCapture] context crop — center=(%.3f,%.3f) size=(%.3f,%.3f) hAxis=(%.3f,%.3f) vAxis=(%.3f,%.3f) liftedTip=(%.3f,%.3f)",
            crop.center.x, crop.center.y, crop.size.width, crop.size.height,
            crop.axes.horizontal.x, crop.axes.horizontal.y,
            crop.axes.vertical.x, crop.axes.vertical.y,
            liftedTip.x, liftedTip.y)
      #endif
      pendingWordCaptureTip = liftedTip
      pendingWordCaptureCrop = crop
      ocrDebugCrop = crop
      refreshGestureActiveFlag()
      capturePhoto()
    } else {
      // Fallback: no document detected, use legacy fixed crop
      triggerOCRCapture(tipNormalized: liftedTip)
    }
  }

  private func handlePhotoData(_ uiImage: UIImage) {
    if let crops = self.pendingPassageCrops {
      self.pendingPassageCrops = nil
      Task { await self.processPassagePhoto(image: uiImage, crops: crops) }
    } else if let tip = self.pendingWordCaptureTip, let crop = self.pendingWordCaptureCrop {
      self.pendingWordCaptureTip = nil
      self.pendingWordCaptureCrop = nil
      self.refreshGestureActiveFlag()
      Task { await self.processWordPhoto(image: uiImage, contextCrop: crop, fingerTip: tip) }
    } else if let pendingTip = self.pendingOCRTip {
      self.pendingOCRTip = nil
      self.refreshGestureActiveFlag()
      Task { await self.processOCRPhoto(image: uiImage, tipNormalized: pendingTip) }
    } else {
      self.capturedPhoto = uiImage
      self.showPhotoPreview = true
    }
  }

  // MARK: - Streaming Lifecycle

  func handleStartStreaming() async {
    switch cameraMode {
    case .glasses:
      guard let wearables else { return }
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
        showError("Permission error: \(error.localizedDescription)")
      }

    case .phoneCamera:
      await startSession()
    }
  }

  func startSession() async {
    // Always create a reading session so orphan captures made during the
    // cover-first flow have a container. `activeBook` is nil while cover
    // identification is still running; when the match (or failure) lands,
    // the `$phase` subscription updates this same session in place rather
    // than creating a new one.
    let session = ReadingSession(book: activeBook)
    modelContext.insert(session)
    try? modelContext.save()
    activeSession = session

    switch cameraMode {
    case .glasses:
      await streamSession?.start()
    case .phoneCamera:
      await phoneCameraService?.start()
      streamingStatus = .streaming
    }
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  private func refreshGestureActiveFlag() {
    let active = highlightPhase != .idle || pendingOCRTip != nil || pendingWordCaptureTip != nil
    flowBridge.setIsGestureActive(active)
  }

  func stopSession() async {
    // Finalize the reading session
    if let activeSession {
      activeSession.endedAt = Date()
      try? modelContext.save()
    }
    // Surface the session to the orphan-link sheet if identification never
    // bound a book. Must run BEFORE resetForNewStream() clears lastFailedAttempt,
    // though we actually read session.identificationFailed which is persisted
    // on the model — independent of the service's in-memory state.
    if let session = activeSession,
       session.book == nil,
       session.identificationFailed {
      pendingOrphanSession = session
    }
    pendingOCRTip = nil
    pendingWordCaptureTip = nil
    refreshGestureActiveFlag()
    coverDetector.resetCooldown()
    pendingWordCaptureCrop = nil
    pendingPassageCrops = nil
    ocrDebugCrop = nil
    handPoseService.reset()
    pageTrackingService.reset()
    highlightTracker.reset()
    wordConversation.stop()
    pageScanLoopTask?.cancel()
    pageScanLoopTask = nil
    pageScanStatusHideTask?.cancel()
    pageScanStatusHideTask = nil
    pageScanStatus = .idle
    pageProgressTracker.reset()
    pageROILearner.reset()
    bookIDCancellable?.cancel()
    bookIDCancellable = nil
    bookIdentification.resetForNewStream()
    currentPage = nil
    pagesPerMinute = nil
    lastRawPageValues = []
    pageScanDebugCrops = []
    pageScanIsLocked = false
    highlightPhase = .idle
    currentUnderlineSelection = nil
    startMarkerCamera = nil
    highlightStripSelection = nil
    highlightStartColumn = nil
    lastCapturedPassage = nil
    hevcDecoder.invalidate()

    switch cameraMode {
    case .glasses:
      await streamSession?.stop()
    case .phoneCamera:
      phoneCameraService?.stop()
      streamingStatus = .stopped
    }
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func capturePhoto() {
    switch cameraMode {
    case .glasses:
      streamSession?.capturePhoto(format: .jpeg)
    case .phoneCamera:
      phoneCameraService?.capturePhoto()
    }
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
    pendingOCRTip = tipNormalized
    refreshGestureActiveFlag()
    #if DEBUG
    NSLog("[OCR] photo capture triggered — tip=(%.3f, %.3f)", tipNormalized.x, tipNormalized.y)
    #endif
    capturePhoto()
  }

  /// Triggers passage extraction after a highlight gesture completes.
  /// The oriented strip crops are precomputed in the hand-tracking callback;
  /// this just stashes them for the photo callback and fires capture.
  private func triggerPassageExtraction(crops: [OrientedCrop]) {
    guard !crops.isEmpty else { return }
    #if DEBUG
    NSLog("[Highlight] passage extraction triggered — %d oriented strips", crops.count)
    for (i, crop) in crops.enumerated() {
      NSLog("[Highlight]   strip %d: center=(%.3f,%.3f) size=(%.3f,%.3f) hAxis=(%.3f,%.3f) vAxis=(%.3f,%.3f)",
            i, crop.center.x, crop.center.y, crop.size.width, crop.size.height,
            crop.axes.horizontal.x, crop.axes.horizontal.y,
            crop.axes.vertical.x, crop.axes.vertical.y)
    }
    #endif
    pendingPassageCrops = crops
    capturePhoto()
  }

  private func processPassagePhoto(image: UIImage, crops: [OrientedCrop]) async {
    // Extract each oriented strip as an upright UIImage so the OCR service sees horizontal text.
    let strips: [UIImage] = crops.compactMap { $0.extractUpright(from: image) }
    guard !strips.isEmpty else {
      #if DEBUG
      NSLog("[Highlight] no strips extracted from photo")
      #endif
      return
    }
    let service = passageExtractionService
    let result = await Task.detached(priority: .userInitiated) {
      await service.extractPassage(strips: strips)
    }.value

    guard !result.text.isEmpty else {
      #if DEBUG
      NSLog("[Highlight] no text extracted from selection")
      #endif
      withAnimation(.spring(duration: 0.3)) {
        lastCapturedPassage = "(No text detected in selection)"
      }
      try? await Task.sleep(for: .seconds(2))
      withAnimation(.easeOut(duration: 0.3)) { lastCapturedPassage = nil }
      return
    }

    // Save to SwiftData
    let imageData = result.croppedRegionImage?.jpegData(compressionQuality: 0.85)
    let passage = CapturedPassage(text: result.text, imageData: imageData, book: activeBook, pageNumber: currentPage)
    modelContext.insert(passage)
    try? modelContext.save()

    // Show toast
    withAnimation(.spring(duration: 0.3)) {
      lastCapturedPassage = result.text
    }
    try? await Task.sleep(for: .seconds(4))
    withAnimation(.easeOut(duration: 0.3)) {
      if lastCapturedPassage == result.text { lastCapturedPassage = nil }
    }
  }

  private func processWordPhoto(image: UIImage, contextCrop: OrientedCrop, fingerTip: CGPoint) async {
    // Extract the oriented context region as an upright UIImage — after rotation, the crop's
    // local Vision coord space has the fingertip near the bottom of the rect.
    guard let upright = contextCrop.extractUpright(from: image) else {
      #if DEBUG
      NSLog("[WordContext] upright extraction failed")
      #endif
      return
    }
    // Transform fingertip from camera Vision coords → book-axis offset from crop center →
    // crop-local normalized 0–1 coords. Because the basis may be non-orthogonal, we solve
    // the 2×2 linear system rather than using a dot product.
    let h = contextCrop.axes.horizontal
    let v = contextCrop.axes.vertical
    let det = h.x * v.y - h.y * v.x
    let dx = fingerTip.x - contextCrop.center.x
    let dy = fingerTip.y - contextCrop.center.y
    let localX: CGFloat
    let localY: CGFloat
    if abs(det) > 1e-9 {
      localX = (v.y * dx - v.x * dy) / det
      localY = (-h.y * dx + h.x * dy) / det
    } else {
      localX = 0
      localY = 0
    }
    let fingerTipInCrop = CGPoint(
      x: min(max(localX / contextCrop.size.width + 0.5, 0), 1),
      y: min(max(localY / contextCrop.size.height + 0.5, 0), 1)
    )
    let service = wordCaptureService
    let result = await Task.detached(priority: .userInitiated) {
      await service.recognizeWordInContext(contextImage: upright, fingerTipInCrop: fingerTipInCrop)
    }.value

    // Show the word image as live preview
    withAnimation(.spring(duration: 0.25)) {
      currentOCRCrop = result.wordImage ?? result.contextImage
    }

    // Save to SwiftData with context
    let imageData = result.wordImage?.jpegData(compressionQuality: 0.85)
    let captured = CapturedWord(
      text: result.word,
      imageData: imageData,
      contextPhrase: result.contextPhrase,
      book: activeBook,
      pageNumber: currentPage
    )
    modelContext.insert(captured)
    try? modelContext.save()

    // Kick off the spoken conversation flow: concise spoken definition via TTS,
    // then open the mic with VAD for follow-up questions. Fire-and-forget —
    // runs independently of the structured definition save below. Any in-flight
    // conversation from a previous capture is cancelled automatically.
    if !result.word.isEmpty && !result.contextPhrase.isEmpty {
      wordConversation.start(
        word: result.word,
        sentenceContext: result.contextPhrase,
        bookTitle: activeBook?.title
      )
    }

    // Auto-lookup definition with context
    if !result.word.isEmpty {
      let wordText = result.word
      let bookTitle = activeBook?.title
      let contextPhrase = result.contextPhrase
      let ctx = modelContext
      Task.detached {
        do {
          let def: WordDefinition
          if await OnDeviceLLMService.shared.isReady {
            def = try await OnDeviceLLMService.shared.generateDefinition(
              word: wordText, bookTitle: bookTitle, context: contextPhrase
            )
            print("[LLM] ✅ '\(wordText)' → \(def.definition.prefix(60))…")
          } else {
            def = try await DefinitionService().lookUp(word: wordText)
            print("[Dict] ✅ '\(wordText)' → \(def.definition.prefix(60))…")
          }
          await MainActor.run {
            captured.definition = def.definition
            captured.pronunciation = def.pronunciation.isEmpty ? nil : def.pronunciation
            captured.exampleSentence = def.exampleSentence.isEmpty ? nil : def.exampleSentence
            try? ctx.save()
          }
        } catch {
          print("[Definition] ❌ '\(wordText)' failed: \(error.localizedDescription)")
        }
      }
    }

    guard !result.word.isEmpty else {
      try? await Task.sleep(for: .seconds(5))
      withAnimation(.easeOut(duration: 0.3)) {
        currentOCRCrop = nil
        ocrDebugCrop = nil
      }
      return
    }

    withAnimation(.spring(duration: 0.3)) { lastCapturedWord = result.word }
    try? await Task.sleep(for: .seconds(5))
    withAnimation(.easeOut(duration: 0.3)) {
      if lastCapturedWord == result.word { lastCapturedWord = nil }
      currentOCRCrop = nil
      ocrDebugCrop = nil
    }
  }

  private func processOCRPhoto(image: UIImage, tipNormalized: CGPoint) async {
    // Use the video-stream tip position directly — both video and photo are in Vision
    // normalized coords (0–1). The tip from the video stream is accurate enough;
    // re-running full hand pose inference on the high-res photo was the single most
    // expensive operation in the OCR path and is eliminated here.
    let w: CGFloat = 0.12, h: CGFloat = 0.05
    let centerY = tipNormalized.y + 0.02
    let cropRect = CGRect(
      x: max(0, tipNormalized.x - w / 2),
      y: max(0, centerY - h / 2),
      width: w, height: h
    )

    #if DEBUG
    NSLog("[OCR] processing photo — tip=(%.3f,%.3f) size=%dx%d",
          tipNormalized.x, tipNormalized.y,
          Int(image.size.width), Int(image.size.height))
    #endif

    let service = wordCaptureService
    let result = await Task.detached(priority: .userInitiated) {
      await service.recognizeWord(in: image, cropRect: cropRect)
    }.value
    #if DEBUG
    NSLog("[OCR] result: \"%@\"", result.text)
    #endif

    // Show the original (non-processed) crop as the live stream preview
    withAnimation(.spring(duration: 0.25)) {
      currentOCRCrop = result.originalCrop
    }

    // Save to review list — only persist the original crop, not the preprocessed (upscaled) image
    let imageData = result.originalCrop.flatMap { $0.jpegData(compressionQuality: 0.85) }
    let captured = CapturedWord(text: result.text, imageData: imageData, book: activeBook, pageNumber: currentPage)
    modelContext.insert(captured)
    try? modelContext.save()

    // Auto-lookup definition in the background
    if !result.text.isEmpty {
      let wordText = result.text
      let bookTitle = activeBook?.title
      let ctx = modelContext
      Task.detached {
        do {
          let def: WordDefinition
          // Use on-device LLM if already loaded; otherwise fall back to dictionary API
          if await OnDeviceLLMService.shared.isReady {
            def = try await OnDeviceLLMService.shared.generateDefinition(
              word: wordText, bookTitle: bookTitle
            )
            print("[LLM] ✅ '\(wordText)' → \(def.definition.prefix(60))…")
          } else {
            def = try await DefinitionService().lookUp(word: wordText)
            print("[Dict] ✅ '\(wordText)' → \(def.definition.prefix(60))…")
          }
          await MainActor.run {
            captured.definition = def.definition
            captured.pronunciation = def.pronunciation.isEmpty ? nil : def.pronunciation
            captured.exampleSentence = def.exampleSentence.isEmpty ? nil : def.exampleSentence
            try? ctx.save()
          }
        } catch {
          print("[Definition] ❌ '\(wordText)' failed: \(error.localizedDescription)")
        }
      }
    }

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

  // MARK: - Periodic Page Number Scanning

  /// Launches the background task that OCRs the visible page to detect the
  /// current page number. Cancelled in `stopSession()`.
  ///
  /// The loop runs in two modes: while the active book has no learned ROI
  /// (`pageNumberROI == nil`), scans fire continuously at OCR-bound speed so
  /// the ROI locks in as quickly as possible. Once the ROI is committed, the
  /// loop drops to the 30-second cadence — page numbers don't change between
  /// frames, so the only reason to scan is to track page transitions, which
  /// 30 s easily covers.
  ///
  /// The first scan fires after a short warm-up delay so the first video frame
  /// and document quad have a chance to arrive.
  private func startPageScanLoop() {
    pageScanLoopTask?.cancel()
    pageScanLoopTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      while !Task.isCancelled {
        await self?.performPageScan()
        if Task.isCancelled { return }
        // Use the per-call-site interval: fast yield while learning, long
        // sleep once locked. Reading the flag on the main actor via `self?`
        // is correct because `performPageScan` already hopped us there.
        let interval = await self?.currentPageScanInterval ?? 30
        try? await Task.sleep(for: .seconds(interval))
      }
    }
  }

  /// Selects the appropriate scan cadence based on whether the active book
  /// already has a learned ROI. Evaluated on the main actor between iterations.
  private var currentPageScanInterval: TimeInterval {
    if activeBook?.pageNumberROI != nil {
      return pageScanLockedInterval
    }
    return pageScanLearningInterval
  }

  /// Single scan pass. Runs learning mode until a per-book ROI is committed, then
  /// locked mode using just the stored rect. Skips when the hand is mid-gesture or
  /// when there is no active book / frame / quad.
  private func performPageScan() async {
    guard !isPageScanRunning else { return }
    guard highlightPhase == .idle else { return }
    guard let book = activeBook else {
      if pageScanStatus != .idle { pageScanStatus = .idle }
      return
    }
    guard let image = currentVideoFrame else { return }
    guard let quad = debugTrackingQuad else { return }
    isPageScanRunning = true
    defer { isPageScanRunning = false }

    // First tick of a learning-mode session → surface "Searching…" to the UI.
    // The locked path never touches pageScanStatus so a previously-set
    // .located state from this session keeps its auto-hide timing.
    if book.pageNumberROI == nil, pageScanStatus == .idle {
      pageScanStatus = .searching
    }

    let axes = pageTrackingService.currentBookAxes()
    let detector = pageNumberDetector

    // Update the debug overlay with the rectangles we're about to OCR.
    pageScanDebugCrops = detector.debugScanCrops(quad: quad, axes: axes, roi: book.pageNumberROI)
    pageScanIsLocked = book.pageNumberROI != nil

    if let roi = book.pageNumberROI {
      // Locked mode: OCR just the learned rect.
      let candidate = await Task.detached(priority: .utility) {
        detector.scanLocked(image: image, quad: quad, axes: axes, roi: roi)
      }.value

      if let candidate {
        lastRawPageValues = [candidate.value]
        var updated = roi
        updated.missStreak = 0
        book.pageNumberROI = updated
        applyCommit(pageProgressTracker.observe(value: candidate.value, now: Date()), book: book)
      } else {
        lastRawPageValues = []
        var updated = roi
        updated.missStreak += 1
        if updated.missStreak >= lockedROIMissLimit {
          #if DEBUG
          NSLog("[PageScan] locked ROI missed %d times, restarting learning", updated.missStreak)
          #endif
          book.pageNumberROI = nil
          pageROILearner.reset()
          // Reverting to learning mode — surface the status pill again so the
          // user sees that the detector is hunting for a new ROI.
          pageScanStatusHideTask?.cancel()
          pageScanStatus = .searching
        } else {
          book.pageNumberROI = updated
        }
      }
      try? modelContext.save()
      return
    }

    // Learning mode: scan the margins.
    let candidates = await Task.detached(priority: .utility) {
      detector.scanLearning(image: image, quad: quad, axes: axes)
    }.value

    #if DEBUG
    NSLog("[PageScan] learning — %d candidates", candidates.count)
    #endif

    // Publish every raw value we saw this scan for the debug overlay — sorted and
    // deduped so the chip is readable.
    lastRawPageValues = Array(Set(candidates.map(\.value))).sorted()

    // Use the most confident candidate (the max value, as a stand-in for "reading frontier")
    // to feed the progress tracker while we wait for the ROI learner to converge.
    if let topValue = candidates.map(\.value).max() {
      applyCommit(pageProgressTracker.observe(value: topValue, now: Date()), book: book)
    }

    if let learned = pageROILearner.observe(candidates) {
      #if DEBUG
      NSLog("[PageScan] ROI learned — rect=(%.3f,%.3f,%.3f,%.3f)",
            learned.rect.origin.x, learned.rect.origin.y, learned.rect.width, learned.rect.height)
      #endif
      book.pageNumberROI = learned
      try? modelContext.save()
      // Surface the commit as a transient "Page number located" pill.
      // Auto-hides after 3 s so it doesn't clutter the overlay.
      transitionPageScanStatusToLocated()
    }
  }

  /// Flips the status pill to `.located` and schedules it to fall back to
  /// `.idle` after 3 seconds. Idempotent — a second call while a hide task is
  /// already pending simply resets the timer.
  private func transitionPageScanStatusToLocated() {
    pageScanStatus = .located
    pageScanStatusHideTask?.cancel()
    pageScanStatusHideTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard let self, !Task.isCancelled else { return }
      if self.pageScanStatus == .located {
        self.pageScanStatus = .idle
      }
    }
  }

  /// Apply a committed page transition to the view model's published state and to the
  /// persisted session/book. Safe to call with `nil` — does nothing in that case.
  private func applyCommit(_ commit: PageCommit?, book: Book) {
    guard let commit else { return }
    currentPage = commit.page
    pagesPerMinute = pageProgressTracker.pagesPerMinute(now: Date())
    book.lastReadPage = commit.page
    if let session = activeSession {
      if session.startPage == nil { session.startPage = commit.page }
      session.endPage = commit.page
    }
    try? modelContext.save()
  }

  private func updateStatusFromState(_ state: StreamSessionState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
      handPoseService.reset()
      pageTrackingService.reset()
      wordConversation.stop()
      highlightTracker.reset()
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
    case .deviceNotFound(_):
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected(_):
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "The hinges on the glasses were closed. Please open the hinges and try again."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }
}

// MARK: - FlowBridge (thread-safe bridge between video listener and main thread)

/// Lock-protected container for data written on the video frame background thread
/// and consumed on the main thread. Not bound to @MainActor.
private final class FlowBridge: @unchecked Sendable {
  private let lock = NSLock()
  private var _quad: PageTrackingService.DocumentQuad?
  private var _pixelBuffer: CVPixelBuffer?
  private var _isGestureActive: Bool = false

  func store(result: PageTrackingService.TrackingResult?, pixelBuffer: CVPixelBuffer) {
    lock.lock()
    _quad = result?.quad
    _pixelBuffer = pixelBuffer
    lock.unlock()
  }

  func currentQuad() -> PageTrackingService.DocumentQuad? {
    lock.lock()
    defer { lock.unlock() }
    return _quad
  }

  func currentPixelBuffer() -> CVPixelBuffer? {
    lock.lock()
    defer { lock.unlock() }
    return _pixelBuffer
  }

  func setIsGestureActive(_ value: Bool) {
    lock.lock()
    _isGestureActive = value
    lock.unlock()
  }

  func isGestureActive() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return _isGestureActive
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
