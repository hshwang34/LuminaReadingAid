//
// HandOverlayView.swift
//
// Canvas-based SwiftUI overlay that draws the hand skeleton, joint landmarks,
// and pinch gesture feedback on top of the live video feed.
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
      guard trackingResult.isValidPose,
            let landmarks = trackingResult.landmarks else { return }
      drawSkeleton(context: context, landmarks: landmarks)
      drawJoints(context: context, landmarks: landmarks)
      drawPinchFeedback(context: context, landmarks: landmarks)
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
    context.stroke(path, with: .color(.white.opacity(0.8)), lineWidth: 1.5)
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
      context.fill(Path(ellipseIn: rect), with: .color(.yellow))
    }
  }

  /// Draws a line between thumb tip and index PIP to show pinch proximity,
  /// and highlights both joints green when a pinch is triggered.
  private func drawPinchFeedback(context: GraphicsContext, landmarks: HandLandmarks) {
    guard let thumbNorm = landmarks.point(for: .thumbTip),
          let pipNorm = landmarks.point(for: .indexPIP) else { return }

    let thumbPt = convert(thumbNorm)
    let pipPt = convert(pipNorm)

    switch trackingResult.pinchState {
    case .open:
      // Show a thin line between thumb and PIP so the user can see the gap closing
      var line = Path()
      line.move(to: thumbPt)
      line.addLine(to: pipPt)
      context.stroke(line, with: .color(.white.opacity(0.5)), lineWidth: 1.5)

    case .triggered:
      // Highlight both joints and the connecting line in green during cooldown
      var line = Path()
      line.move(to: thumbPt)
      line.addLine(to: pipPt)
      context.stroke(line, with: .color(.green), lineWidth: 2.5)
      drawSpotDot(context: context, center: thumbPt, size: 12, color: .green)
      drawSpotDot(context: context, center: pipPt, size: 12, color: .green)
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
}
