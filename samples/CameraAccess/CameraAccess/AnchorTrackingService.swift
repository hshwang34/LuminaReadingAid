//
// AnchorTrackingService.swift
//
// Tracks the book's position using VNDetectDocumentSegmentationRequest every frame.
// Returns the actual quadrilateral corners (not just the axis-aligned bounding box),
// so rotated books are represented accurately.
//
// All book-relative coordinates are anchored to the top-left corner of the document,
// which is the most stable reference point (furthest from the hand during underlining).
//

import Vision
import CoreVideo
import CoreGraphics
import Foundation

final class PageTrackingService {

  // MARK: - Public Types

  /// Four corners of the detected document quadrilateral, in Vision coords (0–1, bottom-left).
  struct DocumentQuad {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomLeft: CGPoint
    let bottomRight: CGPoint

    var center: CGPoint {
      CGPoint(
        x: (topLeft.x + topRight.x + bottomLeft.x + bottomRight.x) / 4,
        y: (topLeft.y + topRight.y + bottomLeft.y + bottomRight.y) / 4
      )
    }
  }

  struct TrackingResult {
    let quad: DocumentQuad
    let confidence: Float
  }

  // MARK: - Private State

  private let processingQueue = DispatchQueue(
    label: "com.Lumina.ReadingAid.pagetrack",
    qos: .userInitiated
  )

  /// Latest detected document quadrilateral.
  private var latestQuad: DocumentQuad?

  /// EMA-smoothed book axes, both unit vectors in camera Vision coords.
  /// `horizontal` = smoothed direction of topLeft→topRight.
  /// `vertical` = smoothed direction of the unoccluded vertical edge, chosen by `handedness`:
  ///   - right-handed: bottomLeft → topLeft (left edge — right hand hovers over BR)
  ///   - left-handed : bottomRight → topRight (right edge — left hand hovers over BL)
  private var smoothedAxes: BookAxisBasis = .identity
  private var hasAxesSeed: Bool = false
  /// Light smoothing — ~3-frame window at 30fps. Higher = more responsive, more jitter.
  private let tiltSmoothingAlpha: CGFloat = 0.35
  /// Minimum VNRectangleObservation.confidence to accept a document detection.
  /// Frames below this threshold fall back to the cached `latestQuad` to prevent
  /// noisy low-confidence detections (e.g. during hand occlusion) from jittering the box.
  private let minimumConfidence: Float = 0.5
  /// Maximum single-frame corner displacement (Vision normalized units) allowed.
  /// Anything larger is treated as an outlier (Vision misfire / teleport) and the
  /// frame is rejected, keeping the cached quad. No EMA smoothing — accepted frames
  /// write raw corners straight through.
  private let maxCornerJump: CGFloat = 0.08
  /// How many consecutive frames we're willing to reject before concluding that
  /// the cached quad is stale (e.g., the initial seed locked onto the wrong object
  /// or the user moved the book drastically). Once we hit this count, we accept the
  /// next detection — even one that would normally fail the teleport check — so the
  /// tracker can recover. 10 frames ≈ 0.33s at 30fps / 0.67s at 15fps.
  private let maxStaleFrames: Int = 10
  /// Consecutive frames where the raw detection has been rejected (either by outlier
  /// filter or no-detection). Reset to 0 every time we accept a frame.
  private var rejectedFrameCount: Int = 0
  /// Which corners feed the vertical axis. Re-read from UserDefaults on each reset so a
  /// future onboarding / settings UI can toggle it by just writing to `Handedness.userDefaultsKey`.
  private var handedness: Handedness = PageTrackingService.loadHandedness()

  /// Reads the user's handedness preference from UserDefaults. Defaults to `.right`.
  private static func loadHandedness() -> Handedness {
    guard let raw = UserDefaults.standard.string(forKey: Handedness.userDefaultsKey),
          let value = Handedness(rawValue: raw) else {
      return .right
    }
    return value
  }

  // MARK: - Public API

  /// Call every video frame. Runs document detection and returns the quad.
  /// Low-confidence frames and single-frame outliers fall back to the cached quad
  /// so the overlay stays stable. If too many consecutive rejections pile up, the
  /// cached quad is considered stale and the next sane detection is accepted.
  func processFrame(_ pixelBuffer: CVPixelBuffer) -> TrackingResult? {
    return processingQueue.sync {
      guard let detection = detectDocument(in: pixelBuffer) else {
        // No detection (or rejected as low-confidence) — reuse cached quad if available.
        rejectedFrameCount += 1
        guard let cached = latestQuad else { return nil }
        return TrackingResult(quad: cached, confidence: 0.0)
      }

      // Sanity check — always required. No (0, 0) or wildly out-of-bounds corners
      // are ever accepted, even through the stale override below.
      guard isDetectionSane(detection.quad) else {
        rejectedFrameCount += 1
        #if DEBUG
        NSLog("[PageTracking] rejecting degenerate detection — keeping cached quad")
        #endif
        if let cached = latestQuad {
          return TrackingResult(quad: cached, confidence: 0.0)
        }
        return nil
      }

      // Teleport check — the new corners must be close to the cached ones, UNLESS
      // we've been rejecting for so long that the cached quad is clearly stale.
      let isClose = isCloseToCached(detection.quad)
      let staleOverride = rejectedFrameCount >= maxStaleFrames

      if !isClose && !staleOverride {
        rejectedFrameCount += 1
        #if DEBUG
        NSLog("[PageTracking] rejecting outlier (rejectedCount=\(rejectedFrameCount)) — keeping cached quad")
        #endif
        if let cached = latestQuad {
          return TrackingResult(quad: cached, confidence: 0.0)
        }
        return nil
      }

      #if DEBUG
      if staleOverride && !isClose {
        NSLog("[PageTracking] stale override — accepting far detection after \(rejectedFrameCount) rejections")
      }
      #endif

      // Accepted — write through raw corners, reset the rejection counter.
      latestQuad = detection.quad
      rejectedFrameCount = 0
      updateSmoothedAxes(for: detection.quad)
      return TrackingResult(quad: detection.quad, confidence: detection.confidence)
    }
  }

  /// Returns `true` when the detection has plausible corner positions.
  /// Rejects degenerate corners: out-of-bounds, negative, or at origin.
  /// This check always runs — it's never overridden.
  private func isDetectionSane(_ raw: DocumentQuad) -> Bool {
    func inBounds(_ p: CGPoint) -> Bool {
      let lo: CGFloat = -0.02, hi: CGFloat = 1.02
      return p.x >= lo && p.x <= hi && p.y >= lo && p.y <= hi
        && !(p.x == 0 && p.y == 0)
    }
    return inBounds(raw.topLeft)
      && inBounds(raw.topRight)
      && inBounds(raw.bottomLeft)
      && inBounds(raw.bottomRight)
  }

  /// Returns `true` when the raw corners are within `maxCornerJump` of the cached quad.
  /// When there's no cached quad yet (first detection), returns `true` so seeding works.
  private func isCloseToCached(_ raw: DocumentQuad) -> Bool {
    guard let prev = latestQuad else { return true }
    func delta(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
    let maxDelta = max(
      delta(prev.topLeft,     raw.topLeft),
      delta(prev.topRight,    raw.topRight),
      delta(prev.bottomLeft,  raw.bottomLeft),
      delta(prev.bottomRight, raw.bottomRight)
    )
    return maxDelta <= maxCornerJump
  }

  /// Returns the current smoothed book axes. Identity (x-right, y-up) when no quad yet.
  func currentBookAxes() -> BookAxisBasis {
    processingQueue.sync {
      hasAxesSeed ? smoothedAxes : .identity
    }
  }

  private func updateSmoothedAxes(for quad: DocumentQuad) {
    // Horizontal axis: topLeft → topRight (top edge direction). Top edge is reliable for
    // both handednesses because both hands enter the frame from below.
    let hdx = quad.topRight.x - quad.topLeft.x
    let hdy = quad.topRight.y - quad.topLeft.y
    let hLen = hypot(hdx, hdy)
    guard hLen > 1e-6 else { return }
    let rawH = CGPoint(x: hdx / hLen, y: hdy / hLen)

    // Vertical axis: derived from whichever vertical edge is unoccluded by the user's
    // dominant hand. Both variants point "up the page" (from a bottom corner to the
    // corresponding top corner).
    let vFrom: CGPoint
    let vTo: CGPoint
    switch handedness {
    case .right:
      vFrom = quad.bottomLeft
      vTo = quad.topLeft
    case .left:
      vFrom = quad.bottomRight
      vTo = quad.topRight
    }
    let vdx = vTo.x - vFrom.x
    let vdy = vTo.y - vFrom.y
    let vLen = hypot(vdx, vdy)
    guard vLen > 1e-6 else { return }
    let rawV = CGPoint(x: vdx / vLen, y: vdy / vLen)

    if !hasAxesSeed {
      smoothedAxes = BookAxisBasis(horizontal: rawH, vertical: rawV)
      hasAxesSeed = true
      return
    }

    let alpha = tiltSmoothingAlpha
    let blendedH = CGPoint(
      x: (1 - alpha) * smoothedAxes.horizontal.x + alpha * rawH.x,
      y: (1 - alpha) * smoothedAxes.horizontal.y + alpha * rawH.y
    )
    let blendedV = CGPoint(
      x: (1 - alpha) * smoothedAxes.vertical.x + alpha * rawV.x,
      y: (1 - alpha) * smoothedAxes.vertical.y + alpha * rawV.y
    )
    // Renormalize after blending so both stay unit-length.
    let bhLen = hypot(blendedH.x, blendedH.y)
    let bvLen = hypot(blendedV.x, blendedV.y)
    guard bhLen > 1e-6, bvLen > 1e-6 else { return }
    smoothedAxes = BookAxisBasis(
      horizontal: CGPoint(x: blendedH.x / bhLen, y: blendedH.y / bhLen),
      vertical: CGPoint(x: blendedV.x / bvLen, y: blendedV.y / bvLen)
    )
  }

  /// Convert a camera-space point to book-relative coordinates.
  /// Book-relative = offset from the document's top-left corner.
  func toBookRelative(_ cameraPoint: CGPoint) -> CGPoint? {
    processingQueue.sync {
      guard let quad = latestQuad else { return nil }
      return CGPoint(
        x: cameraPoint.x - quad.topLeft.x,
        y: cameraPoint.y - quad.topLeft.y
      )
    }
  }

  /// Returns the current anchor point (top-left corner) in camera coords.
  func currentAnchor() -> CGPoint? {
    processingQueue.sync {
      return latestQuad?.topLeft
    }
  }

  /// Returns the latest detected quad.
  func currentQuad() -> DocumentQuad? {
    processingQueue.sync {
      return latestQuad
    }
  }

  /// Computes a tilted context crop for word capture, parallel to the book's top edge.
  /// Column width is full single-page (or half-spread), shrunk 5% to avoid the binding/margins.
  /// Height is 1/5 of the page height, extending upward from the fingertip.
  /// Returns nil if no document detected.
  func contextCropRegion(fingerTip: CGPoint) -> OrientedCrop? {
    processingQueue.sync {
      guard let quad = latestQuad else { return nil }

      let axes = hasAxesSeed ? smoothedAxes : .identity
      let layout = PageColumnLayout(
        topLeft: quad.topLeft,
        topRight: quad.topRight,
        bottomLeft: quad.bottomLeft,
        bottomRight: quad.bottomRight,
        axes: axes
      )
      guard layout.bookWidth > 0.01, layout.bookHeight > 0.01 else { return nil }

      // Work in book-axis space: the fingertip gets projected onto the book's level frame,
      // and all rectangle math happens without worrying about tilt.
      let tipBook = layout.toBookAxisSpace(fingerTip)
      let halfW = layout.bookWidth / 2
      let halfH = layout.bookHeight / 2
      let shrink = PageColumnLayout.shrinkFactor

      // Pick the column the fingertip is on (book-axis X). In single-column mode the whole
      // page is one column so the split is skipped.
      let colMinX: CGFloat
      let colMaxX: CGFloat
      switch layout.mode {
      case .twoColumn:
        let halfColWidth = halfW
        let shrunkHalf = halfColWidth * shrink
        if tipBook.x < 0 {
          let mid = -halfColWidth / 2
          colMinX = mid - shrunkHalf / 2
          colMaxX = mid + shrunkHalf / 2
        } else {
          let mid = halfColWidth / 2
          colMinX = mid - shrunkHalf / 2
          colMaxX = mid + shrunkHalf / 2
        }
      case .singleColumn:
        let shrunk = halfW * shrink
        colMinX = -shrunk
        colMaxX = shrunk
      }

      // Vertical range: 1/5 page height above the fingertip, clamped to the top of the book.
      let contextHeight = layout.bookHeight / 5
      let cropMinY = tipBook.y
      let cropMaxY = min(tipBook.y + contextHeight, halfH)
      let height = cropMaxY - cropMinY
      let width = colMaxX - colMinX
      guard width > 0.01, height > 0.01 else { return nil }

      let centerBook = CGPoint(
        x: (colMinX + colMaxX) / 2,
        y: (cropMinY + cropMaxY) / 2
      )
      return OrientedCrop(
        center: layout.toCameraSpace(centerBook),
        size: CGSize(width: width, height: height),
        axes: axes
      )
    }
  }

  /// Full reset — call when streaming stops. Re-reads the handedness preference so any
  /// changes made since the previous session take effect immediately on the next one.
  func reset() {
    processingQueue.sync {
      latestQuad = nil
      rejectedFrameCount = 0
      smoothedAxes = .identity
      hasAxesSeed = false
      handedness = PageTrackingService.loadHandedness()
    }
  }

  // MARK: - Private

  private func detectDocument(in pixelBuffer: CVPixelBuffer) -> (quad: DocumentQuad, confidence: Float)? {
    let request = VNDetectDocumentSegmentationRequest()
    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])

    do {
      try handler.perform([request])
    } catch {
      return nil
    }

    guard let result = request.results?.first else {
      return nil
    }

    let box = result.boundingBox
    guard box.width * box.height >= 0.05 else {
      return nil
    }

    // Reject low-confidence detections. Caller falls back to the cached `latestQuad`
    // so the overlay stays stable during hand occlusion / ambiguous frames.
    //
    // Important: `VNDetectDocumentSegmentationRequest` does not meaningfully populate
    // `confidence` — it's a segmentation request that returns a pixel mask + corners,
    // and Apple leaves the inherited `confidence` field at 0.0. So we treat 0.0 as
    // "unknown, trust the geometry instead" and only reject strictly-positive but
    // below-threshold values (preserving the intent of this filter in case a future
    // iOS version ever starts populating it). The real filter is the area check above.
    if result.confidence > 0 && result.confidence < minimumConfidence {
      #if DEBUG
      NSLog("[PageTracking] rejecting low-confidence detection: %.2f", result.confidence)
      #endif
      return nil
    }

    let quad = DocumentQuad(
      topLeft: result.topLeft,
      topRight: result.topRight,
      bottomLeft: result.bottomLeft,
      bottomRight: result.bottomRight
    )
    return (quad, result.confidence)
  }
}
