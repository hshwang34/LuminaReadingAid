//
// HighlightGestureTypes.swift
//
// Data types for the underline-based highlight/passage-save gesture.
// Trail points are stored in book-relative coordinates (offset from book top-left).
// Camera coordinates use Vision space (0–1, bottom-left origin).
//

import CoreGraphics
import CoreImage
import Foundation
import UIKit

// MARK: - Gesture Phase

/// Extended pinch state machine for distinguishing quick-pinch (word lookup)
/// from sustained-pinch-drag (highlight mode).
enum HighlightGesturePhase: Equatable {
  /// No pinch active
  case idle
  /// Pinch detected, waiting to see if it's held long enough (0.3s) for highlighting
  case pinchStarted(at: TimeInterval)
  /// Sustained pinch — actively dragging to underline text
  case highlighting
  /// Pinch released after highlighting — selection is final, awaiting extraction
  case completed
}

// MARK: - Underline Trail

/// Minimum downward y-drop (in book-relative coords) to trigger a new line.
/// In Vision coords, "down the page" = decreasing y.
let kLineBreakThreshold: CGFloat = 0.015

/// A single line of the underline trail, defined by book-relative points.
struct UnderlineTrailLine {
  /// Points in book-relative coordinates (offset from book top-left, Vision coord space).
  var points: [CGPoint]

  /// X range of this line's trail.
  var xRange: ClosedRange<CGFloat> {
    guard let minX = points.map(\.x).min(),
          let maxX = points.map(\.x).max() else { return 0...0 }
    return minX...maxX
  }

  /// Y center of this line (average y of all points).
  var yCenter: CGFloat {
    guard !points.isEmpty else { return 0 }
    return points.map(\.y).reduce(0, +) / CGFloat(points.count)
  }
}

/// Trail-based selection: an ordered array of underline lines in book-relative coordinates.
struct UnderlineSelection {
  /// Latest book top-left in camera coords — updated each frame for conversion back.
  var anchor: CGPoint
  /// Lines of the underline trail, ordered top-to-bottom on the page
  /// (descending Vision y — first line has highest y).
  var lines: [UnderlineTrailLine]

  /// Whether the trail has enough data to be a valid selection.
  var isValid: Bool {
    guard !lines.isEmpty else { return false }
    return lines.contains { line in
      guard line.points.count >= 2 else { return false }
      return (line.xRange.upperBound - line.xRange.lowerBound) >= 0.01
    }
  }

  /// All trail points flattened into camera space (Vision coords 0–1, bottom-left origin).
  var cameraPoints: [CGPoint] {
    lines.flatMap { line in
      line.points.map { CGPoint(x: anchor.x + $0.x, y: anchor.y + $0.y) }
    }
  }
}

// MARK: - Handedness

/// User's dominant hand, used to pick which book corners feed the smoothed axis derivation.
/// A right-hander's right hand occludes the bottom-right corner during gestures, so we derive
/// the vertical axis from the left edge. Left-handers mirror this: their hand occludes the
/// bottom-left corner, so we derive the vertical axis from the right edge.
enum Handedness: String, CaseIterable, Codable {
  case right
  case left

  /// UserDefaults key — shared between `PageTrackingService` (reader) and any future
  /// onboarding/settings UI (writer).
  static let userDefaultsKey = "userHandedness"
}

// MARK: - Book Axis Basis

/// Two unit vectors describing the book's own coordinate frame in camera Vision space.
///
/// `horizontal` points along the top edge (topLeft → topRight).
/// `vertical` points *up the page* from whichever vertical edge is unobstructed by the user's
/// dominant hand (left edge for right-handers, right edge for left-handers). Aligned with
/// Vision's y-up convention.
///
/// The two axes are **not required to be perpendicular** — document segmentation can produce
/// a parallelogram quad when the book is skewed in the camera's view. Using both axes
/// independently (rather than deriving one from the other as a 90° rotation) ensures the
/// crop parallelogram tracks both edges correctly even under perspective skew.
struct BookAxisBasis: Equatable {
  var horizontal: CGPoint
  var vertical: CGPoint

  /// Level-book default: x right, y up.
  static let identity = BookAxisBasis(
    horizontal: CGPoint(x: 1, y: 0),
    vertical: CGPoint(x: 0, y: 1)
  )
}

// MARK: - Oriented Crop

/// A parallelogram crop in camera space, aligned with the book's two independent edges.
///
/// `center` and `size` are in Vision normalized coords. `axes` provides the two directions
/// along which `size.width` and `size.height` extend — allowing the crop to track both the
/// top edge tilt AND the left edge tilt, producing a parallelogram (not just a rotated rect).
struct OrientedCrop: Equatable {
  var center: CGPoint
  var size: CGSize
  var axes: BookAxisBasis

  /// 4 corners of the parallelogram in camera space, ordered TL → TR → BR → BL
  /// (relative to the book's own frame, not screen orientation).
  var corners: [CGPoint] {
    let hw = size.width / 2
    let hh = size.height / 2
    let h = axes.horizontal
    let v = axes.vertical
    return [
      CGPoint(x: center.x - hw * h.x + hh * v.x, y: center.y - hw * h.y + hh * v.y),  // TL
      CGPoint(x: center.x + hw * h.x + hh * v.x, y: center.y + hw * h.y + hh * v.y),  // TR
      CGPoint(x: center.x + hw * h.x - hh * v.x, y: center.y + hw * h.y - hh * v.y),  // BR
      CGPoint(x: center.x - hw * h.x - hh * v.x, y: center.y - hw * h.y - hh * v.y),  // BL
    ]
  }

  /// Axis-aligned bounding box of the parallelogram in camera space.
  var boundingBox: CGRect {
    let pts = corners
    let xs = pts.map(\.x)
    let ys = pts.map(\.y)
    let minX = xs.min() ?? 0
    let maxX = xs.max() ?? 0
    let minY = ys.min() ?? 0
    let maxY = ys.max() ?? 0
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  /// Extracts the parallelogram region from a captured photo as an upright axis-aligned UIImage
  /// by solving for the affine transform that maps the 3 defining corners (BL, BR, TL) of the
  /// parallelogram to the output canvas corners, then applying it to the source.
  ///
  /// Works for both pure-rotation and sheared parallelograms — handles the case where the
  /// top edge and left edge aren't perpendicular.
  func extractUpright(from image: UIImage) -> UIImage? {
    guard let cgImage = image.cgImage else { return nil }
    let ciImage = CIImage(cgImage: cgImage)
      .oriented(forExifOrientation: Int32(image.imageOrientation.orientedCropExifValue))
    let extent = ciImage.extent
    let W = extent.width
    let H = extent.height
    let ox = extent.origin.x
    let oy = extent.origin.y

    // Convert the four normalized corners to pixel coords in the oriented image (y-up).
    let pts = corners
    guard pts.count == 4 else { return nil }
    let tlPx = CGPoint(x: pts[0].x * W + ox, y: pts[0].y * H + oy)
    let trPx = CGPoint(x: pts[1].x * W + ox, y: pts[1].y * H + oy)
    let brPx = CGPoint(x: pts[2].x * W + ox, y: pts[2].y * H + oy)
    let blPx = CGPoint(x: pts[3].x * W + ox, y: pts[3].y * H + oy)

    // Output pixel dims = length of top edge × length of left edge.
    let topEdgeLen = hypot(trPx.x - tlPx.x, trPx.y - tlPx.y)
    let leftEdgeLen = hypot(tlPx.x - blPx.x, tlPx.y - blPx.y)
    let outW = floor(topEdgeLen)
    let outH = floor(leftEdgeLen)
    guard outW > 1, outH > 1 else { return nil }

    // Parallelogram area guard (degenerate = zero area = skip).
    let hx = trPx.x - tlPx.x
    let hy = trPx.y - tlPx.y
    let vx = tlPx.x - blPx.x
    let vy = tlPx.y - blPx.y
    let parallelogramArea = abs(hx * vy - hy * vx)
    guard parallelogramArea > 1 else { return nil }
    _ = brPx  // BR is implied by the parallelogram — suppress unused warning.

    // Build the inverse transform (canvas → source pixel). In CIImage y-up:
    //   canvas (0,       0)    → blPx (book bottom-left)
    //   canvas (outW,    0)    → brPx (book bottom-right)
    //   canvas (0,    outH)    → tlPx (book top-left)
    let a = (brPx.x - blPx.x) / outW
    let b = (brPx.y - blPx.y) / outW
    let c = (tlPx.x - blPx.x) / outH
    let d = (tlPx.y - blPx.y) / outH
    let invTransform = CGAffineTransform(a: a, b: b, c: c, d: d, tx: blPx.x, ty: blPx.y)
    let forwardTransform = invTransform.inverted()

    let transformed = ciImage.transformed(by: forwardTransform)
    let outRect = CGRect(x: 0, y: 0, width: outW, height: outH)

    let ctx = CIContext(options: [.useSoftwareRenderer: false])
    guard let result = ctx.createCGImage(transformed, from: outRect) else { return nil }
    return UIImage(cgImage: result, scale: image.scale, orientation: .up)
  }
}

// MARK: - Page Layout

/// Which page of the open book a gesture is acting on.
enum PageColumn {
  case left
  case right
}

/// Whether the detected document is an open two-page spread or a single page.
enum PageLayoutMode {
  /// Wider than tall → open book spread, split into left and right columns at the spine.
  case twoColumn
  /// Taller than wide → single page facing the camera, one column spanning the full width.
  case singleColumn
}

/// Book-axis layout derived from a `DocumentQuad` and the smoothed book axes.
///
/// All column geometry lives in **book-axis space** — a (possibly non-orthogonal) frame where
/// the book's top edge is the X axis and the left edge is the Y axis. Points in camera space
/// are lifted into book-axis space via `toBookAxisSpace` so strip math isn't affected by tilt
/// or skew. The two axes are stored so the crops come out as parallelograms tracking both
/// edges independently.
struct PageColumnLayout {
  var mode: PageLayoutMode
  var axes: BookAxisBasis
  /// Book center in camera Vision coords.
  var bookCenter: CGPoint
  /// Book width along its X axis, in Vision normalized units.
  var bookWidth: CGFloat
  /// Book height along its Y axis, in Vision normalized units.
  var bookHeight: CGFloat
  /// Oriented column crops, already tracking both book edges.
  /// In `.singleColumn` mode, `leftColumn` is the full page and `rightColumn` is nil.
  var leftColumn: OrientedCrop?
  var rightColumn: OrientedCrop?

  /// How much to shrink each column inward to avoid the binding and outer margins.
  static let shrinkFactor: CGFloat = 0.95

  /// Determinant of the [[h.x, v.x], [h.y, v.y]] basis matrix.
  /// Equals sin(angle between h and v) for unit vectors. Used by the inverse transform.
  private var basisDeterminant: CGFloat {
    axes.horizontal.x * axes.vertical.y - axes.horizontal.y * axes.vertical.x
  }

  /// Build a layout from the four quad corners plus the current smoothed axes.
  init(
    topLeft: CGPoint,
    topRight: CGPoint,
    bottomLeft: CGPoint,
    bottomRight: CGPoint,
    axes: BookAxisBasis
  ) {
    self.axes = axes

    // Book center: centroid of the four corners.
    let center = CGPoint(
      x: (topLeft.x + topRight.x + bottomLeft.x + bottomRight.x) / 4,
      y: (topLeft.y + topRight.y + bottomLeft.y + bottomRight.y) / 4
    )
    self.bookCenter = center

    // Project each corner into book-axis space. For a non-orthogonal basis we solve the
    // 2×2 linear system rather than using a dot product.
    let det = axes.horizontal.x * axes.vertical.y - axes.horizontal.y * axes.vertical.x
    func toBookAxis(_ p: CGPoint) -> CGPoint {
      let dx = p.x - center.x
      let dy = p.y - center.y
      guard abs(det) > 1e-9 else { return .zero }
      let bx = (axes.vertical.y * dx - axes.vertical.x * dy) / det
      let by = (-axes.horizontal.y * dx + axes.horizontal.x * dy) / det
      return CGPoint(x: bx, y: by)
    }
    let tl = toBookAxis(topLeft)
    let tr = toBookAxis(topRight)
    let bl = toBookAxis(bottomLeft)
    let br = toBookAxis(bottomRight)

    let bookMinX = min(tl.x, tr.x, bl.x, br.x)
    let bookMaxX = max(tl.x, tr.x, bl.x, br.x)
    let bookMinY = min(tl.y, tr.y, bl.y, br.y)
    let bookMaxY = max(tl.y, tr.y, bl.y, br.y)
    let bookW = max(0, bookMaxX - bookMinX)
    let bookH = max(0, bookMaxY - bookMinY)
    self.bookWidth = bookW
    self.bookHeight = bookH

    // Aspect ratio → mode. Wider than tall = open spread.
    self.mode = bookW >= bookH ? .twoColumn : .singleColumn

    // Convert a book-axis point back to camera space using the forward basis transform.
    func bookToCamera(_ p: CGPoint) -> CGPoint {
      CGPoint(
        x: center.x + p.x * axes.horizontal.x + p.y * axes.vertical.x,
        y: center.y + p.x * axes.horizontal.y + p.y * axes.vertical.y
      )
    }

    let shrink = PageColumnLayout.shrinkFactor

    switch self.mode {
    case .twoColumn:
      // Each half-page: left = [-bookW/2, 0], right = [0, bookW/2] in book-axis space.
      let halfWidth = bookW / 2
      let shrunkHalfWidth = halfWidth * shrink
      let leftCenterX = -halfWidth / 2
      let rightCenterX = halfWidth / 2
      let centerYBook = (bookMinY + bookMaxY) / 2
      self.leftColumn = OrientedCrop(
        center: bookToCamera(CGPoint(x: leftCenterX, y: centerYBook)),
        size: CGSize(width: shrunkHalfWidth, height: bookH),
        axes: axes
      )
      self.rightColumn = OrientedCrop(
        center: bookToCamera(CGPoint(x: rightCenterX, y: centerYBook)),
        size: CGSize(width: shrunkHalfWidth, height: bookH),
        axes: axes
      )
    case .singleColumn:
      let shrunkWidth = bookW * shrink
      let centerXBook = (bookMinX + bookMaxX) / 2
      let centerYBook = (bookMinY + bookMaxY) / 2
      self.leftColumn = OrientedCrop(
        center: bookToCamera(CGPoint(x: centerXBook, y: centerYBook)),
        size: CGSize(width: shrunkWidth, height: bookH),
        axes: axes
      )
      self.rightColumn = nil
    }
  }

  /// Transform a camera-space point into book-axis space (solves 2×2 linear system).
  func toBookAxisSpace(_ cameraPoint: CGPoint) -> CGPoint {
    let det = basisDeterminant
    guard abs(det) > 1e-9 else { return .zero }
    let dx = cameraPoint.x - bookCenter.x
    let dy = cameraPoint.y - bookCenter.y
    let bx = (axes.vertical.y * dx - axes.vertical.x * dy) / det
    let by = (-axes.horizontal.y * dx + axes.horizontal.x * dy) / det
    return CGPoint(x: bx, y: by)
  }

  /// Transform a book-axis point back into camera space via the forward basis transform.
  func toCameraSpace(_ bookAxisPoint: CGPoint) -> CGPoint {
    CGPoint(
      x: bookCenter.x + bookAxisPoint.x * axes.horizontal.x + bookAxisPoint.y * axes.vertical.x,
      y: bookCenter.y + bookAxisPoint.x * axes.horizontal.y + bookAxisPoint.y * axes.vertical.y
    )
  }
}

// MARK: - Column-Strip Selection

/// Oriented OCR strips derived from an in-progress or completed highlight gesture.
/// Each strip is an `OrientedCrop` parallelogram tracking both book edges.
struct ColumnStripSelection: Equatable {
  var leftStrip: OrientedCrop?
  var rightStrip: OrientedCrop?

  /// Crops in reading order (left before right).
  var crops: [OrientedCrop] {
    [leftStrip, rightStrip].compactMap { $0 }
  }

  var isEmpty: Bool { leftStrip == nil && rightStrip == nil }
}

extension UnderlineSelection {
  /// Compute tilted column strips given the current page layout and start-column lock.
  ///
  /// Everything runs in book-axis space so the math is unaffected by book tilt or skew. Rules:
  /// - Single-column stroke → one strip spanning the full column width between min/max Y.
  /// - Left start, points reach right column → two strips stitched in reading order.
  /// - Right start, points leak into left → reverse direction; lock to right column only.
  func columnStrips(
    layout: PageColumnLayout,
    startColumn: PageColumn
  ) -> ColumnStripSelection {
    let bookPoints = cameraPoints.map { layout.toBookAxisSpace($0) }
    guard !bookPoints.isEmpty else { return ColumnStripSelection() }

    let halfW = layout.bookWidth / 2
    let halfH = layout.bookHeight / 2
    let shrink = PageColumnLayout.shrinkFactor

    // Column bounds in book-axis space.
    let leftMinX, leftMaxX, rightMinX, rightMaxX: CGFloat
    let spineMidXBook: CGFloat

    switch layout.mode {
    case .twoColumn:
      let halfColWidth = halfW
      let shrunkHalf = halfColWidth * shrink
      let leftMidX = -halfColWidth / 2
      let rightMidX = halfColWidth / 2
      leftMinX = leftMidX - shrunkHalf / 2
      leftMaxX = leftMidX + shrunkHalf / 2
      rightMinX = rightMidX - shrunkHalf / 2
      rightMaxX = rightMidX + shrunkHalf / 2
      spineMidXBook = 0
    case .singleColumn:
      let shrunk = halfW * shrink
      leftMinX = -shrunk
      leftMaxX = shrunk
      rightMinX = 0
      rightMaxX = 0
      spineMidXBook = halfW + 1
    }

    let leftPoints = bookPoints.filter { $0.x < spineMidXBook }
    let rightPoints = bookPoints.filter { $0.x >= spineMidXBook }

    // Build an OrientedCrop from a book-axis axis-aligned rect.
    func makeStrip(minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat) -> OrientedCrop? {
      let clampedMinY = max(-halfH, minY)
      let clampedMaxY = min(halfH, maxY)
      guard clampedMaxY > clampedMinY, maxX > minX else { return nil }
      let width = maxX - minX
      let height = clampedMaxY - clampedMinY
      let centerBook = CGPoint(x: (minX + maxX) / 2, y: (clampedMinY + clampedMaxY) / 2)
      return OrientedCrop(
        center: layout.toCameraSpace(centerBook),
        size: CGSize(width: width, height: height),
        axes: layout.axes
      )
    }

    switch startColumn {
    case .left:
      if rightPoints.isEmpty {
        guard let yMin = leftPoints.map(\.y).min(),
              let yMax = leftPoints.map(\.y).max() else {
          return ColumnStripSelection()
        }
        return ColumnStripSelection(
          leftStrip: makeStrip(minX: leftMinX, maxX: leftMaxX, minY: yMin, maxY: yMax),
          rightStrip: nil
        )
      } else {
        let leftStartY = leftPoints.map(\.y).max() ?? halfH
        let rightEndY = rightPoints.map(\.y).min() ?? -halfH
        return ColumnStripSelection(
          leftStrip: makeStrip(minX: leftMinX, maxX: leftMaxX, minY: -halfH, maxY: leftStartY),
          rightStrip: makeStrip(minX: rightMinX, maxX: rightMaxX, minY: rightEndY, maxY: halfH)
        )
      }
    case .right:
      guard !rightPoints.isEmpty,
            let yMin = rightPoints.map(\.y).min(),
            let yMax = rightPoints.map(\.y).max() else {
        return ColumnStripSelection()
      }
      return ColumnStripSelection(
        leftStrip: nil,
        rightStrip: makeStrip(minX: rightMinX, maxX: rightMaxX, minY: yMin, maxY: yMax)
      )
    }
  }
}

// MARK: - UIImage.Orientation → EXIF value

private extension UIImage.Orientation {
  /// EXIF orientation integer accepted by `CIImage.oriented(forExifOrientation:)`.
  var orientedCropExifValue: Int {
    switch self {
    case .up:            return 1
    case .upMirrored:    return 2
    case .down:          return 3
    case .downMirrored:  return 4
    case .leftMirrored:  return 5
    case .right:         return 6
    case .rightMirrored: return 7
    case .left:          return 8
    @unknown default:    return 1
    }
  }
}
