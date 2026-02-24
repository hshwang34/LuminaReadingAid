//
// HandTrackingTypes.swift
//
// Shared data types for hand tracking: configuration, landmarks, stillness state, and results.
//

import Vision
import CoreGraphics

// MARK: - Configuration

struct HandTrackingConfig {
  /// Process every Nth frame (3 = ~5fps hand tracking at 15fps stream)
  let frameSkip: Int = 3
  /// Radius in pixels within which the fingertip must stay to count as stationary
  let stationaryRadiusPixels: CGFloat = 15.0
  /// Duration the fingertip must remain stationary before triggering
  let stationaryDurationSeconds: TimeInterval = 1.0
  /// Minimum confidence threshold for landmark detection
  let minimumConfidence: Float = 0.3
  /// Extension ratio above which the index finger is considered extended
  let indexExtensionThreshold: CGFloat = 0.80
  /// Extension ratio below which the middle finger is considered curled
  let curledExtensionThreshold: CGFloat = 0.70

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

// MARK: - Stillness State

enum StillnessState: Equatable {
  case inactive
  case tracking(progress: Double)  // 0.0 – 1.0
  case triggered
}

// MARK: - Result

struct HandTrackingResult {
  let landmarks: HandLandmarks?
  let stillnessState: StillnessState
  let isValidPose: Bool
  let timestamp: TimeInterval

  static let empty = HandTrackingResult(
    landmarks: nil,
    stillnessState: .inactive,
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
