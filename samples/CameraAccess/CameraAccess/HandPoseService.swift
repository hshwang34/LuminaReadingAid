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

  // Reusable Vision request — avoids per-frame allocation.
  // maximumHandCount = 2: Vision has no pre-inference chirality filter, so we must
  // detect all hands and filter for right-hand post-inference. With count=1, Vision
  // may return only the left hand if it scores higher, leaving the filter empty.
  private let handPoseRequest: VNDetectHumanHandPoseRequest = {
    let req = VNDetectHumanHandPoseRequest()
    req.maximumHandCount = 2
    return req
  }()

  // Pinch tracking (accessed only on processingQueue)
  private var pinchTracker: PinchTracker

  // Spatial lock: tracks one hand by wrist position continuity.
  // Prevents the "other" hand from hijacking tracking when it briefly appears.
  // All accessed only on processingQueue.
  private var trackedWristPosition: CGPoint?
  private var consecutiveDetections: Int = 0
  private var consecutiveMisses: Int = 0
  private let lockRadius: CGFloat = 0.15        // max wrist movement between processed frames
  private let acquisitionFrames: Int = 3         // frames to stabilize before accepting
  private let lockReleaseFrames: Int = 5         // consecutive misses before releasing lock

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

      guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
      self.detectHandPose(in: pixelBuffer)
    }
  }

  /// Call with an already-decoded pixel buffer (e.g. from HEVC decoder).
  /// Internally skips frames according to config.frameSkip.
  func processFrame(_ pixelBuffer: CVPixelBuffer) {
    processingQueue.async { [weak self] in
      guard let self else { return }

      self.frameCounter += 1
      guard self.frameCounter % self.config.frameSkip == 0 else { return }

      self.detectHandPose(in: pixelBuffer)
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
    #if DEBUG
    NSLog("[HandPose] photo detection — rawSize=%dx%d orientation=%d",
          cgImage.width, cgImage.height, orientation.rawValue)
    #endif

    let request = VNDetectHumanHandPoseRequest()
    request.maximumHandCount = 2  // detect both, filter for right
    let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
    do {
      try handler.perform([request])
    } catch {
      #if DEBUG
      NSLog("[HandPose] photo detection error: %@", error.localizedDescription)
      #endif
      return nil
    }

    // One-shot photo detection: apply both gates (right-hand + key-joint confidence),
    // then pick the first match. Spatial lock doesn't apply to single photos.
    guard let observation = request.results?
      .filter({ isRightHand($0) && hasConfidentKeyJoints($0) })
      .first else {
      #if DEBUG
      NSLog("[HandPose] no right hand with confident key joints in photo")
      #endif
      return nil
    }

    let landmarks = extractLandmarks(from: observation)

    guard isValidPose(landmarks) else {
      #if DEBUG
      NSLog("[HandPose] photo pose invalid (key joints not visible)")
      #endif
      return nil
    }

    guard let tip = landmarks.point(for: .indexTip) else { return nil }
    #if DEBUG
    NSLog("[HandPose] photo tip detected at (%.3f, %.3f)", tip.x, tip.y)
    #endif
    return tip
  }

  /// Clears all accumulated state. Call when streaming stops.
  func reset() {
    processingQueue.async { [weak self] in
      guard let self else { return }
      self.frameCounter = 0
      self.pinchTracker.reset()
      self.trackedWristPosition = nil
      self.consecutiveDetections = 0
      self.consecutiveMisses = 0
      let result = HandTrackingResult(landmarks: nil, pinchState: .open, isValidPose: false, timestamp: Date.timeIntervalSinceReferenceDate, pinchDistance: nil)
      self.resultPublisher.send(result)
    }
  }

  // MARK: - Hand Selection (Spatial Lock)

  /// Returns true if the three key pinch joints (thumbTip, indexTip, indexPIP) are all
  /// detected with high confidence. This is the primary filter for rejecting palm-up
  /// left hands holding a book — the curled/occluded index finger produces low confidence
  /// and fails the gate, which the 2D crossZ test cannot catch.
  private func hasConfidentKeyJoints(_ observation: VNHumanHandPoseObservation) -> Bool {
    guard let thumbTip = try? observation.recognizedPoint(.thumbTip),
          let indexTip = try? observation.recognizedPoint(.indexTip),
          let indexPIP = try? observation.recognizedPoint(.indexPIP) else {
      return false
    }
    return thumbTip.confidence >= config.keyJointConfidence
        && indexTip.confidence >= config.keyJointConfidence
        && indexPIP.confidence >= config.keyJointConfidence
  }

  /// Returns true if the observation's wrist→thumb→pinky winding order indicates a right hand.
  /// Uses a 2D cross product of vectors from wrist to thumbCMC and wrist to littleMCP.
  /// Calibrated from live glasses data:
  ///   Right hand: crossZ always negative (-0.012 to -0.021)
  ///   Left hand:  crossZ always positive (+0.010 to +0.018)
  private func isRightHand(_ observation: VNHumanHandPoseObservation) -> Bool {
    guard let wrist     = try? observation.recognizedPoint(.wrist),
          let thumbCMC  = try? observation.recognizedPoint(.thumbCMC),
          let littleMCP = try? observation.recognizedPoint(.littleMCP),
          wrist.confidence > config.minimumConfidence,
          thumbCMC.confidence > config.minimumConfidence,
          littleMCP.confidence > config.minimumConfidence else {
      return false  // Can't determine orientation — reject
    }
    let toThumb  = CGPoint(x: thumbCMC.location.x  - wrist.location.x,
                           y: thumbCMC.location.y  - wrist.location.y)
    let toLittle = CGPoint(x: littleMCP.location.x - wrist.location.x,
                           y: littleMCP.location.y - wrist.location.y)
    let crossZ = toThumb.x * toLittle.y - toThumb.y * toLittle.x
    return crossZ < 0
  }

  /// Selects a hand observation using spatial lock + temporal stability.
  ///
  /// - If a hand is currently tracked (wrist position known), picks the observation
  ///   whose wrist is closest to the last known position, within `lockRadius`.
  /// - If no hand is tracked, picks the observation with the highest-confidence wrist.
  /// - Requires `acquisitionFrames` consecutive detections before returning an observation.
  /// - Releases the lock after `lockReleaseFrames` consecutive misses.
  ///
  /// **Must be called on `processingQueue`.**
  private func selectTrackedHand(
    from results: [VNHumanHandPoseObservation]?
  ) -> VNHumanHandPoseObservation? {
    guard let results, !results.isEmpty else {
      consecutiveMisses += 1
      if consecutiveMisses >= lockReleaseFrames {
        trackedWristPosition = nil
        consecutiveDetections = 0
      }
      return nil
    }

    // Extract wrist position and confidence for each observation
    let candidates: [(obs: VNHumanHandPoseObservation, wrist: CGPoint, confidence: Float)] =
      results.compactMap { obs in
        guard let wrist = try? obs.recognizedPoint(.wrist),
              wrist.confidence > config.minimumConfidence else { return nil }
        return (obs, wrist.location, wrist.confidence)
      }

    guard !candidates.isEmpty else {
      consecutiveMisses += 1
      if consecutiveMisses >= lockReleaseFrames {
        trackedWristPosition = nil
        consecutiveDetections = 0
      }
      return nil
    }

    let selected: (obs: VNHumanHandPoseObservation, wrist: CGPoint, confidence: Float)

    if let tracked = trackedWristPosition {
      // Locked: find the closest hand within lockRadius
      let closest = candidates
        .map { (candidate: $0, dist: hypot($0.wrist.x - tracked.x, $0.wrist.y - tracked.y)) }
        .filter { $0.dist <= lockRadius }
        .min(by: { $0.dist < $1.dist })

      guard let match = closest else {
        // No hand near the tracked position
        consecutiveMisses += 1
        if consecutiveMisses >= lockReleaseFrames {
          trackedWristPosition = nil
          consecutiveDetections = 0
        }
        return nil
      }
      selected = match.candidate
    } else {
      // No lock — pick highest confidence wrist to start tracking
      selected = candidates.max(by: { $0.confidence < $1.confidence })!
    }

    // Update tracking state
    trackedWristPosition = selected.wrist
    consecutiveMisses = 0
    consecutiveDetections += 1

    // Require N consecutive frames before emitting (temporal stability)
    guard consecutiveDetections >= acquisitionFrames else {
      return nil
    }

    return selected.obs
  }

  // MARK: - Vision Processing

  private func detectHandPose(in pixelBuffer: CVPixelBuffer) {
    // Capture a single timestamp for the entire frame — avoid repeated Date calls
    let now = Date.timeIntervalSinceReferenceDate

    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer)
    do {
      try handler.perform([handPoseRequest])
    } catch {
      return
    }

    // Pre-filter: only hands that pass BOTH gates enter the spatial lock:
    //   1. crossZ winding order → right hand (rejects palm-down left hands)
    //   2. key joints (thumbTip, indexTip, indexPIP) all >= 0.7 confidence
    //      (rejects palm-up left hands holding a book, where the index finger
    //      is occluded — a case crossZ cannot distinguish from a right hand)
    // This prevents the lock from latching onto a rejected hand and blocking
    // right-hand acquisition on subsequent frames.
    let filteredResults = handPoseRequest.results?.filter {
      isRightHand($0) && hasConfidentKeyJoints($0)
    }

    guard let observation = selectTrackedHand(from: filteredResults) else {
      pinchTracker.reset()
      resultPublisher.send(HandTrackingResult(
        landmarks: nil,
        pinchState: .open,
        isValidPose: false,
        timestamp: now,
        pinchDistance: nil
      ))
      return
    }

    let landmarks = extractLandmarks(from: observation)

    // Compute raw pinch distance for HighlightGestureTracker (bypasses PinchTracker cooldown)
    let pinchDistance: CGFloat? = {
      guard let thumb = landmarks.point(for: .thumbTip),
            let pip = landmarks.point(for: .indexPIP) else { return nil }
      return hypot(thumb.x - pip.x, thumb.y - pip.y)
    }()

    guard isValidPose(landmarks) else {
      pinchTracker.reset()
      resultPublisher.send(HandTrackingResult(
        landmarks: landmarks,
        pinchState: .open,
        isValidPose: false,
        timestamp: now,
        pinchDistance: pinchDistance
      ))
      return
    }

    let pinchState = pinchTracker.update(
      thumbTip: landmarks.point(for: .thumbTip),
      indexPIP: landmarks.point(for: .indexPIP),
      at: now
    )

    resultPublisher.send(HandTrackingResult(
      landmarks: landmarks,
      pinchState: pinchState,
      isValidPose: true,
      timestamp: now,
      pinchDistance: pinchDistance
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
