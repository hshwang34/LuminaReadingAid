//
// SelectionOverlayView.swift
//
// Canvas-based overlay that draws the underline trail on top of the live video feed.
// Trail points are in book-relative coordinates and converted to camera coords,
// then to SwiftUI view coords for rendering.
//

import SwiftUI

struct SelectionOverlayView: View {
  let selection: UnderlineSelection?
  let startMarker: CGPoint?
  let gesturePhase: HighlightGesturePhase
  let imageSize: CGSize
  let viewSize: CGSize
  /// Debug: the document segmentation quadrilateral. Drawn as cyan outline.
  let debugTrackingQuad: PageTrackingService.DocumentQuad?
  /// Live OCR strip preview — shown as semi-transparent yellow fill under the finger trail.
  let stripSelection: ColumnStripSelection?

  var body: some View {
    Canvas { context, _ in
      // Debug: draw the document quadrilateral
      if let quad = debugTrackingQuad {
        drawTrackingQuad(context: context, quad: quad)
      }

      switch gesturePhase {
      case .highlighting, .completed:
        // Draw strips first so the finger trail renders on top and stays clearly visible.
        if let strips = stripSelection {
          drawColumnStrips(context: context, strips: strips)
        }
        if let sel = selection {
          drawUnderlineTrail(context: context, selection: sel)
        }
      case .pinchStarted:
        if let marker = startMarker {
          drawStartMarker(context: context, point: marker)
        }
      default:
        break
      }
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
    let viewY = (1.0 - normalized.y) * scaledHeight - offsetY

    return CGPoint(x: viewX, y: viewY)
  }

  /// Converts a book-relative point to camera coords, then to SwiftUI view coords.
  private func convertBookRelative(_ bookRelative: CGPoint, anchor: CGPoint) -> CGPoint {
    let camera = CGPoint(
      x: anchor.x + bookRelative.x,
      y: anchor.y + bookRelative.y
    )
    return convert(camera)
  }

  // MARK: - Drawing

  /// Draws the underline trail as thick yellow paths, one per line.
  private func drawUnderlineTrail(context: GraphicsContext, selection: UnderlineSelection) {
    let center = selection.anchor

    for line in selection.lines {
      guard line.points.count >= 2 else { continue }

      var path = Path()
      let first = convertBookRelative(line.points[0], anchor: center)
      path.move(to: first)

      for point in line.points.dropFirst() {
        let viewPt = convertBookRelative(point, anchor: center)
        path.addLine(to: viewPt)
      }

      context.stroke(
        path,
        with: .color(.yellow.opacity(0.8)),
        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
      )
    }
  }

  /// Draws the live column-strip preview as semi-transparent yellow polygons with a solid border,
  /// tilted to match the book's top edge.
  private func drawColumnStrips(context: GraphicsContext, strips: ColumnStripSelection) {
    for crop in strips.crops {
      let viewPoints = crop.corners.map { convert($0) }
      guard viewPoints.count == 4 else { continue }
      var path = Path()
      path.move(to: viewPoints[0])
      for pt in viewPoints.dropFirst() {
        path.addLine(to: pt)
      }
      path.closeSubpath()
      context.fill(path, with: .color(.yellow.opacity(0.2)))
      context.stroke(path, with: .color(.yellow.opacity(0.9)), lineWidth: 1.5)
    }
  }

  /// Draws the document quadrilateral as a cyan dashed outline (debug).
  private func drawTrackingQuad(context: GraphicsContext, quad: PageTrackingService.DocumentQuad) {
    let tl = convert(quad.topLeft)
    let tr = convert(quad.topRight)
    let br = convert(quad.bottomRight)
    let bl = convert(quad.bottomLeft)

    var path = Path()
    path.move(to: tl)
    path.addLine(to: tr)
    path.addLine(to: br)
    path.addLine(to: bl)
    path.closeSubpath()

    context.stroke(
      path,
      with: .color(.cyan),
      style: StrokeStyle(lineWidth: 2, dash: [6, 4])
    )

    // Draw center crosshair
    let center = convert(quad.center)
    var cross = Path()
    cross.move(to: CGPoint(x: center.x - 8, y: center.y))
    cross.addLine(to: CGPoint(x: center.x + 8, y: center.y))
    cross.move(to: CGPoint(x: center.x, y: center.y - 8))
    cross.addLine(to: CGPoint(x: center.x, y: center.y + 8))
    context.stroke(cross, with: .color(.cyan), lineWidth: 2)
  }

  /// Draws a marker dot at the start position while waiting for the hold threshold.
  private func drawStartMarker(context: GraphicsContext, point: CGPoint) {
    let center = convert(point)
    let size: CGFloat = 14
    let rect = CGRect(
      x: center.x - size / 2,
      y: center.y - size / 2,
      width: size,
      height: size
    )
    context.fill(Path(ellipseIn: rect), with: .color(.yellow.opacity(0.7)))
    context.stroke(Path(ellipseIn: rect), with: .color(.yellow), lineWidth: 2)
  }
}
