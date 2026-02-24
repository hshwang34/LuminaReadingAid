//
// HandOverlayView.swift
//
// Canvas-based SwiftUI overlay that draws the hand skeleton, joint landmarks,
// and a stillness progress ring on top of the live video feed.
//

import SwiftUI
import Vision

struct HandOverlayView: View {
  let trackingResult: HandTrackingResult
  /// Native pixel size of the video frame (e.g. 720×1280)
  let imageSize: CGSize
  /// Size of the SwiftUI view in screen points
  let viewSize: CGSize

  var body: some View {
    Canvas { context, size in
      guard let landmarks = trackingResult.landmarks else { return }
      drawSkeleton(context: context, landmarks: landmarks)
      drawJoints(context: context, landmarks: landmarks)
      drawIndexTipHighlight(context: context, landmarks: landmarks)
    }
    .allowsHitTesting(false)
  }

  // MARK: - Coordinate Conversion

  /// Converts a Vision normalized point (0–1, bottom-left origin) to SwiftUI view coordinates,
  /// accounting for .aspectRatio(.fill) + .clipped() rendering.
  private func convert(_ normalized: CGPoint) -> CGPoint {
    guard imageSize.width > 0, imageSize.height > 0 else { return .zero }

    let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
    let scaledWidth = imageSize.width * scale
    let scaledHeight = imageSize.height * scale
    let offsetX = (scaledWidth - viewSize.width) / 2
    let offsetY = (scaledHeight - viewSize.height) / 2

    let viewX = normalized.x * scaledWidth - offsetX
    // Vision Y is bottom-left; SwiftUI Y is top-left
    let viewY = (1.0 - normalized.y) * scaledHeight - offsetY

    return CGPoint(x: viewX, y: viewY)
  }

  // MARK: - Drawing

  private func drawSkeleton(context: GraphicsContext, landmarks: HandLandmarks) {
    var path = Path()
    for (startJoint, endJoint) in HandSkeleton.connections {
      guard
        let startNorm = landmarks.point(for: startJoint),
        let endNorm = landmarks.point(for: endJoint)
      else { continue }

      let start = convert(startNorm)
      let end = convert(endNorm)
      path.move(to: start)
      path.addLine(to: end)
    }
    let skeletonColor: Color = trackingResult.isValidPose ? .white.opacity(0.8) : .red.opacity(0.8)
    context.stroke(path, with: .color(skeletonColor), lineWidth: 1.5)
  }

  private func drawJoints(context: GraphicsContext, landmarks: HandLandmarks) {
    for (_, normalized) in landmarks.points {
      let center = convert(normalized)
      let dotSize: CGFloat = 8
      let rect = CGRect(
        x: center.x - dotSize / 2,
        y: center.y - dotSize / 2,
        width: dotSize,
        height: dotSize
      )
      let jointColor: Color = trackingResult.isValidPose ? .yellow : .red
      context.fill(Path(ellipseIn: rect), with: .color(jointColor))
    }
  }

  private func drawIndexTipHighlight(context: GraphicsContext, landmarks: HandLandmarks) {
    guard trackingResult.isValidPose else { return }
    guard let indexTipNorm = landmarks.point(for: .indexTip) else { return }
    let center = convert(indexTipNorm)

    switch trackingResult.stillnessState {
    case .inactive:
      // No extra highlight beyond the standard yellow joint dot
      break

    case .tracking(let progress):
      // Green dot (12pt) + partial arc showing progress
      drawSpotDot(context: context, center: center, size: 12, color: .green)
      drawProgressArc(context: context, center: center, progress: progress, color: .green)

    case .triggered:
      // Full green dot (12pt) + complete circle
      drawSpotDot(context: context, center: center, size: 12, color: .green)
      drawProgressArc(context: context, center: center, progress: 1.0, color: .green)
    }
  }

  private func drawSpotDot(context: GraphicsContext, center: CGPoint, size: CGFloat, color: Color) {
    let rect = CGRect(
      x: center.x - size / 2,
      y: center.y - size / 2,
      width: size,
      height: size
    )
    context.fill(Path(ellipseIn: rect), with: .color(color))
  }

  private func drawProgressArc(
    context: GraphicsContext,
    center: CGPoint,
    progress: Double,
    color: Color
  ) {
    let radius: CGFloat = 18
    let startAngle = Angle.degrees(-90)
    let endAngle = Angle.degrees(-90 + 360 * progress)

    var arc = Path()
    arc.addArc(
      center: center,
      radius: radius,
      startAngle: startAngle,
      endAngle: endAngle,
      clockwise: false
    )
    context.stroke(arc, with: .color(color), lineWidth: 2.5)
  }
}
