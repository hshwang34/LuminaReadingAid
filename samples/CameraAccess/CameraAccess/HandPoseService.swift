//
// HandPoseService.swift
//
// Vision-based hand pose detection engine. Processes CMSampleBuffer frames on a background
// serial queue, detects index finger tip position, and tracks stillness duration.
//

import Vision
import Combine
import CoreMedia
import CoreGraphics
import Foundation

final class HandPoseService {
  // MARK: - Public

  let resultPublisher = PassthroughSubject<HandTrackingResult, Never>()

  // MARK: - Private

  private let config: HandTrackingConfig
  private let processingQueue = DispatchQueue(label: "com.Lumina.ReadingAid.handpose", qos: .userInitiated)

  // Frame skip counter
  private var frameCounter = 0

  // Stillness tracking (accessed only on processingQueue)
  private var stillnessTracker: StillnessTracker

  // MARK: - Init

  init(config: HandTrackingConfig = .default) {
    self.config = config
    self.stillnessTracker = StillnessTracker(config: config)
  }

  // MARK: - Public API

  /// Call on every video frame from the SDK callback thread.
  /// Internally skips frames according to config.frameSkip.
  func processFrame(_ sampleBuffer: CMSampleBuffer) {
    processingQueue.async { [weak self] in
      guard let self else { return }

      self.frameCounter += 1
      guard self.frameCounter % self.config.frameSkip == 0 else { return }

      self.detectHandPose(in: sampleBuffer)
    }
  }

  /// Clears all accumulated state. Call when streaming stops.
  func reset() {
    processingQueue.async { [weak self] in
      guard let self else { return }
      self.frameCounter = 0
      self.stillnessTracker.reset()
      let result = HandTrackingResult(landmarks: nil, stillnessState: .inactive, isValidPose: false, timestamp: Date.timeIntervalSinceReferenceDate)
      self.resultPublisher.send(result)
    }
  }

  // MARK: - Vision Processing

  private func detectHandPose(in sampleBuffer: CMSampleBuffer) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    let request = VNDetectHumanHandPoseRequest()
    request.maximumHandCount = 1

    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
    do {
      try handler.perform([request])
    } catch {
      return
    }

    guard let observation = request.results?.first else {
      // No hand detected — emit inactive result
      stillnessTracker.reset()
      let result = HandTrackingResult(
        landmarks: nil,
        stillnessState: .inactive,
        isValidPose: false,
        timestamp: Date.timeIntervalSinceReferenceDate
      )
      resultPublisher.send(result)
      return
    }

    // Extract all joints above confidence threshold
    let landmarks = extractLandmarks(from: observation)

    // Gate stillness tracking on a valid pointing pose
    let validPose = isPointingPose(landmarks)
    guard validPose else {
      stillnessTracker.reset()
      resultPublisher.send(HandTrackingResult(
        landmarks: landmarks,
        stillnessState: .inactive,
        isValidPose: false,
        timestamp: Date.timeIntervalSinceReferenceDate
      ))
      return
    }

    // Update stillness tracker with index tip position
    let indexTipPoint = landmarks.point(for: .indexTip)
    let imageSize = CGSize(
      width: CVPixelBufferGetWidth(pixelBuffer),
      height: CVPixelBufferGetHeight(pixelBuffer)
    )
    let stillnessState = stillnessTracker.update(
      normalizedTip: indexTipPoint,
      imageSize: imageSize,
      at: Date.timeIntervalSinceReferenceDate
    )

    resultPublisher.send(HandTrackingResult(
      landmarks: landmarks,
      stillnessState: stillnessState,
      isValidPose: true,
      timestamp: Date.timeIntervalSinceReferenceDate
    ))
  }

  private func extractLandmarks(from observation: VNHumanHandPoseObservation) -> HandLandmarks {
    var points: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
    var confidences: [VNHumanHandPoseObservation.JointName: Float] = [:]

    let allJoints: [VNHumanHandPoseObservation.JointName] = [
      .wrist,
      .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
      .indexMCP, .indexPIP, .indexDIP, .indexTip,
      .middleMCP, .middlePIP, .middleDIP, .middleTip,
      .ringMCP, .ringPIP, .ringDIP, .ringTip,
      .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    for joint in allJoints {
      if let recognized = try? observation.recognizedPoint(joint),
         recognized.confidence > config.minimumConfidence {
        points[joint] = CGPoint(x: recognized.location.x, y: recognized.location.y)
        confidences[joint] = recognized.confidence
      }
    }

    return HandLandmarks(points: points, confidences: confidences)
  }

  // MARK: - Pose Validation

  private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(b.x - a.x, b.y - a.y)
  }

  /// Returns distance(MCP→Tip) / full finger length. Returns 0 if total length is zero.
  private func extensionRatio(mcp: CGPoint, pip: CGPoint, dip: CGPoint, tip: CGPoint) -> CGFloat {
    let totalLength = dist(mcp, pip) + dist(pip, dip) + dist(dip, tip)
    guard totalLength > 0 else { return 0 }
    return dist(mcp, tip) / totalLength
  }

  /// Returns true when landmarks represent a pointing pose:
  /// index extended, middle curled. Thumb, ring, little ignored.
  private func isPointingPose(_ landmarks: HandLandmarks) -> Bool {
    typealias JointName = VNHumanHandPoseObservation.JointName

    func ratio(_ mcp: JointName, _ pip: JointName, _ dip: JointName, _ tip: JointName) -> CGFloat? {
      guard
        let m = landmarks.point(for: mcp),
        let p = landmarks.point(for: pip),
        let d = landmarks.point(for: dip),
        let t = landmarks.point(for: tip)
      else { return nil }
      return extensionRatio(mcp: m, pip: p, dip: d, tip: t)
    }

    guard let indexRatio = ratio(.indexMCP, .indexPIP, .indexDIP, .indexTip) else {
      return false
    }

    // Missing middle joints → treat as curled (occluded by palm = folded in)
    let middleRatio = ratio(.middleMCP, .middlePIP, .middleDIP, .middleTip) ?? 0.0

    return indexRatio  > config.indexExtensionThreshold
        && middleRatio < config.curledExtensionThreshold
  }
}

// MARK: - StillnessTracker

/// Tracks whether the index fingertip has remained within a radius for a given duration.
private final class StillnessTracker {
  private let config: HandTrackingConfig

  private var anchorPixelPoint: CGPoint?
  private var trackingStartTime: TimeInterval?
  private var isTriggered = false

  init(config: HandTrackingConfig) {
    self.config = config
  }

  /// Returns current stillness state given the normalized (0–1) tip position and image dimensions.
  func update(normalizedTip: CGPoint?, imageSize: CGSize, at time: TimeInterval) -> StillnessState {
    guard let normalized = normalizedTip else {
      reset()
      return .inactive
    }

    // Convert normalized Vision coords (bottom-left) to pixel coords (top-left)
    let pixelX = normalized.x * imageSize.width
    let pixelY = (1.0 - normalized.y) * imageSize.height
    let pixelPoint = CGPoint(x: pixelX, y: pixelY)

    if let anchor = anchorPixelPoint {
      let distance = hypot(pixelPoint.x - anchor.x, pixelPoint.y - anchor.y)

      if distance > config.stationaryRadiusPixels {
        // Finger moved — restart tracking from new position
        anchorPixelPoint = pixelPoint
        trackingStartTime = time
        isTriggered = false
        return .tracking(progress: 0.0)
      }

      // Finger is within radius
      if isTriggered {
        return .triggered
      }

      guard let startTime = trackingStartTime else {
        trackingStartTime = time
        return .tracking(progress: 0.0)
      }

      let elapsed = time - startTime
      let progress = min(elapsed / config.stationaryDurationSeconds, 1.0)

      if progress >= 1.0 {
        isTriggered = true
        return .triggered
      }

      return .tracking(progress: progress)
    } else {
      // First detection
      anchorPixelPoint = pixelPoint
      trackingStartTime = time
      isTriggered = false
      return .tracking(progress: 0.0)
    }
  }

  func reset() {
    anchorPixelPoint = nil
    trackingStartTime = nil
    isTriggered = false
  }
}
