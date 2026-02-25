//
// HandPoseService.swift
//
// Vision-based hand pose detection engine. Processes CMSampleBuffer frames on a background
// serial queue, detects a pinch gesture (thumb tip to index PIP), and manages cooldown state.
//

import Vision
import Combine
import CoreMedia
import CoreGraphics
import Foundation
import ImageIO

final class HandPoseService {
  // MARK: - Public

  let resultPublisher = PassthroughSubject<HandTrackingResult, Never>()

  // MARK: - Private

  private let config: HandTrackingConfig
  private let processingQueue = DispatchQueue(label: "com.Lumina.ReadingAid.handpose", qos: .userInitiated)

  // Frame skip counter
  private var frameCounter = 0

  // Pinch tracking (accessed only on processingQueue)
  private var pinchTracker: PinchTracker

  // MARK: - Init

  init(config: HandTrackingConfig = .default) {
    self.config = config
    self.pinchTracker = PinchTracker(config: config)
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

  /// Runs a one-shot hand pose detection on a CGImage (e.g. a captured photo).
  /// Returns the index tip position in Vision normalized coords if a right hand with
  /// visible key joints is found, nil otherwise.
  /// Safe to call from any thread — stateless, does not affect the pinch tracker.
  func detectPointingTip(
    in cgImage: CGImage,
    orientation: CGImagePropertyOrientation
  ) -> CGPoint? {
    NSLog("[HandPose] photo detection — rawSize=%dx%d orientation=%d",
          cgImage.width, cgImage.height, orientation.rawValue)

    let request = VNDetectHumanHandPoseRequest()
    request.maximumHandCount = 1
    let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
    do {
      try handler.perform([request])
    } catch {
      NSLog("[HandPose] photo detection error: %@", error.localizedDescription)
      return nil
    }

    guard let observation = request.results?.first else {
      NSLog("[HandPose] no hand detected in photo")
      return nil
    }

    let landmarks = extractLandmarks(from: observation)

    guard isValidPose(landmarks) else {
      NSLog("[HandPose] photo pose invalid (key joints not visible)")
      return nil
    }

    guard let tip = landmarks.point(for: .indexTip) else { return nil }
    NSLog("[HandPose] photo tip detected at (%.3f, %.3f)", tip.x, tip.y)
    return tip
  }

  /// Clears all accumulated state. Call when streaming stops.
  func reset() {
    processingQueue.async { [weak self] in
      guard let self else { return }
      self.frameCounter = 0
      self.pinchTracker.reset()
      let result = HandTrackingResult(landmarks: nil, pinchState: .open, isValidPose: false, timestamp: Date.timeIntervalSinceReferenceDate)
      self.resultPublisher.send(result)
    }
  }

  // MARK: - Vision Processing

  private func detectHandPose(in sampleBuffer: CMSampleBuffer) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    let request = VNDetectHumanHandPoseRequest()
    request.maximumHandCount = 2

    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
    do {
      try handler.perform([request])
    } catch {
      return
    }

    guard let observation = request.results?.first(where: { obs in
      switch obs.chirality {
      case .right: return true
      case .left:  return false
      case .unknown:
        // Chirality unavailable — fall back to wrist position heuristic.
        // In the egocentric glasses camera the right hand wrist appears on the
        // right side of the frame (x > 0.4 in Vision normalized coords).
        if let wrist = try? obs.recognizedPoint(.wrist), wrist.confidence > 0.3 {
          return wrist.location.x > 0.4
        }
        return false
      @unknown default: return false
      }
    }) else {
      // No right hand detected — emit open result
      pinchTracker.reset()
      resultPublisher.send(HandTrackingResult(
        landmarks: nil,
        pinchState: .open,
        isValidPose: false,
        timestamp: Date.timeIntervalSinceReferenceDate
      ))
      return
    }

    let landmarks = extractLandmarks(from: observation)

    // Log winding order to help calibrate back-of-hand gate.
    // crossZ < 0  → back of right hand (clockwise winding in Vision coords)
    // crossZ ≈ 0  → side view (ambiguous)
    // crossZ > 0  → palm facing camera
    if let wrist     = landmarks.point(for: .wrist),
       let thumbCMC  = landmarks.point(for: .thumbCMC),
       let littleMCP = landmarks.point(for: .littleMCP) {
      let toThumb  = CGPoint(x: thumbCMC.x  - wrist.x, y: thumbCMC.y  - wrist.y)
      let toLittle = CGPoint(x: littleMCP.x - wrist.x, y: littleMCP.y - wrist.y)
      let crossZ   = toThumb.x * toLittle.y - toThumb.y * toLittle.x
      NSLog("[HandPose] crossZ=%.4f (back<0 side≈0 palm>0)", crossZ)
    }

    guard isValidPose(landmarks) else {
      pinchTracker.reset()
      resultPublisher.send(HandTrackingResult(
        landmarks: landmarks,
        pinchState: .open,
        isValidPose: false,
        timestamp: Date.timeIntervalSinceReferenceDate
      ))
      return
    }

    let pinchState = pinchTracker.update(
      thumbTip: landmarks.point(for: .thumbTip),
      indexPIP: landmarks.point(for: .indexPIP),
      at: Date.timeIntervalSinceReferenceDate
    )

    resultPublisher.send(HandTrackingResult(
      landmarks: landmarks,
      pinchState: pinchState,
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

  /// Returns true when the key joints for pinch detection are visible.
  private func isValidPose(_ landmarks: HandLandmarks) -> Bool {
    return landmarks.point(for: .thumbTip) != nil
        && landmarks.point(for: .indexPIP) != nil
  }
}

// MARK: - PinchTracker

/// Detects when thumb tip comes within a normalized distance of index PIP,
/// then holds the triggered state until the thumb moves away and a cooldown expires.
private final class PinchTracker {
  private let config: HandTrackingConfig

  private var inCooldown = false
  private var lastTriggerTime: TimeInterval = 0

  init(config: HandTrackingConfig) {
    self.config = config
  }

  /// Returns the current pinch state given thumb tip and index PIP in Vision normalized coords.
  func update(thumbTip: CGPoint?, indexPIP: CGPoint?, at time: TimeInterval) -> PinchState {
    guard let thumb = thumbTip, let pip = indexPIP else {
      // Key joints not visible — preserve cooldown so it can't be skipped by briefly hiding hand
      return inCooldown ? .triggered : .open
    }

    let distance = hypot(thumb.x - pip.x, thumb.y - pip.y)
    NSLog("[Pinch] dist=%.3f (trigger<%.3f release>%.3f) cooldown=%@",
          distance, config.pinchThreshold, config.pinchReleaseThreshold,
          inCooldown ? "yes" : "no")

    if inCooldown {
      // Exit cooldown only when BOTH: time has elapsed AND thumb has moved away
      let timeElapsed = (time - lastTriggerTime) >= config.pinchCooldownSeconds
      if distance > config.pinchReleaseThreshold && timeElapsed {
        inCooldown = false
      }
      return .triggered
    }

    if distance < config.pinchThreshold {
      inCooldown = true
      lastTriggerTime = time
      return .triggered
    }

    return .open
  }

  func reset() {
    inCooldown = false
    lastTriggerTime = 0
  }
}
