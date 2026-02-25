//
// HandTrackingTypes.swift
//
// Shared data types for hand tracking: configuration, landmarks, pinch state, and results.
//

import Vision
import CoreGraphics

// MARK: - Configuration

struct HandTrackingConfig {
  /// Process every Nth frame (3 = ~5fps hand tracking at 15fps stream)
  let frameSkip: Int = 3
  /// Minimum confidence threshold for landmark detection
  let minimumConfidence: Float = 0.3
  /// Normalized Vision distance (0–1) below which thumb tip to index PIP counts as a pinch
  let pinchThreshold: CGFloat = 0.05
  /// Normalized Vision distance above which the pinch is considered released (hysteresis)
  let pinchReleaseThreshold: CGFloat = 0.08
  /// Minimum seconds in cooldown after a pinch trigger, regardless of release
  let pinchCooldownSeconds: TimeInterval = 1.0

  static let `default` = HandTrackingConfig()
}

// MARK: - Landmarks

/// Dictionary of detected hand joint positions in Vision normalized coordinates (0–1, bottom-left origin)
struct HandLandmarks {
  let points: [VNHumanHandPoseObservation.JointName: CGPoint]
  let confidences: [VNHumanHandPoseObservation.JointName: Float]

  func point(for joint: VNHumanHandPoseObservation.JointName) -> CGPoint? {
    points[joint]
  }
}

// MARK: - Pinch State

enum PinchState: Equatable {
  case open       // thumb tip and index PIP are far apart
  case triggered  // pinch detected; cooldown active until released and time elapsed
}

// MARK: - Result

struct HandTrackingResult {
  let landmarks: HandLandmarks?
  let pinchState: PinchState
  let isValidPose: Bool
  let timestamp: TimeInterval

  static let empty = HandTrackingResult(
    landmarks: nil,
    pinchState: .open,
    isValidPose: false,
    timestamp: 0
  )
}

// MARK: - Skeleton

/// Defines the 20 bone connections for drawing a hand skeleton (5 fingers × 4 bones each)
enum HandSkeleton {
  typealias JointName = VNHumanHandPoseObservation.JointName

  static let connections: [(JointName, JointName)] = [
    // Thumb
    (.wrist, .thumbCMC),
    (.thumbCMC, .thumbMP),
    (.thumbMP, .thumbIP),
    (.thumbIP, .thumbTip),
    // Index
    (.wrist, .indexMCP),
    (.indexMCP, .indexPIP),
    (.indexPIP, .indexDIP),
    (.indexDIP, .indexTip),
    // Middle
    (.wrist, .middleMCP),
    (.middleMCP, .middlePIP),
    (.middlePIP, .middleDIP),
    (.middleDIP, .middleTip),
    // Ring
    (.wrist, .ringMCP),
    (.ringMCP, .ringPIP),
    (.ringPIP, .ringDIP),
    (.ringDIP, .ringTip),
    // Little
    (.wrist, .littleMCP),
    (.littleMCP, .littlePIP),
    (.littlePIP, .littleDIP),
    (.littleDIP, .littleTip),
  ]
}
