//
// CoverDetector.swift
//
// Per-frame state machine that watches the existing document-segmentation
// pipeline for a stable, tall, rectangular cover and emits a CoverCandidate
// when the user is confidently showing a book front cover. Runs on the
// video-frame thread — not MainActor.
//

import Foundation
import CoreVideo
import CoreGraphics

struct CoverCandidate {
  let quad: PageTrackingService.DocumentQuad
  let pixelBuffer: CVPixelBuffer
  let frameTimestamp: CFTimeInterval
}

final class CoverDetector {

  // MARK: - Tunables

  /// Accept both fresh (1.0) and cached (0.5) quads — Vision's document detector
  /// can miss individual frames even when the book is held still; cached quads
  /// are still valid during a held pose.
  private let minConfidence: Float = 0.4
  /// BBox area as fraction of the full frame. Loose — the document detector
  /// already filters <5% — this is an extra floor to keep thumbnails out.
  private let minBBoxArea: CGFloat = 0.10
  /// Aspect ratio (height / width) in display space. Covers 1.35–1.85;
  /// rejects two-page spreads (~0.6–0.85).
  private let minAspect: CGFloat = 1.30
  private let maxAspect: CGFloat = 1.95
  /// Rectangularity floor — mean interior-angle deviation from π/2.
  /// 0.85 allows moderate skew; the perspective warp fixes it.
  private let minRectangularity: Double = 0.85
  /// Opposite-side length parity: `|a − b| / max(a, b) < ratio`.
  /// Loose enough to accept held-at-angle covers; tight enough to reject
  /// trapezoids that aren't really covers.
  private let maxSideParityRatio: CGFloat = 0.18
  /// Normalized drift over driftWindow seconds.
  private let maxCenterDrift: CGFloat = 0.04
  private let driftWindow: TimeInterval = 0.1
  /// Continuous passing frames required before firing. Shortened from 0.8s
  /// because users intentionally show the cover at stream start.
  private let armedDuration: TimeInterval = 0.5
  /// Suppression after firing.
  private let cooldownDuration: TimeInterval = 6.0
  /// If the quad disappears for this long during cooldown, reset early to
  /// let the user show a different book.
  private let absenceResetDuration: TimeInterval = 1.5

  // Debug log throttling so we don't spam NSLog at 30fps.
  private var lastDebugLogTime: CFTimeInterval = 0
  private let debugLogInterval: CFTimeInterval = 0.5

  // MARK: - State

  private enum State {
    case idle
    case armed(since: CFTimeInterval)
    case cooldown(until: CFTimeInterval)
  }

  private var state: State = .idle
  private var lastQuadSeenTime: CFTimeInterval?
  private var driftHistory: [(t: CFTimeInterval, center: CGPoint)] = []

  init() {}

  // MARK: - Public API

  /// Feed every video frame. Returns a CoverCandidate on the exact frame that
  /// satisfies the full stability window; otherwise nil. Pure state machine —
  /// no allocations on the steady path besides the drift ring buffer.
  func ingest(trackingResult: PageTrackingService.TrackingResult?,
              pixelBuffer: CVPixelBuffer,
              isGestureActive: Bool,
              now: CFTimeInterval) -> CoverCandidate? {

    // Gesture suppression — force idle while the user is reading/capturing.
    if isGestureActive {
      if case .armed = state {
        debugLog(now, "suppressed by gesture — reset to idle")
      }
      state = .idle
      driftHistory.removeAll()
      return nil
    }

    // Cooldown gate with early-reset on prolonged quad absence.
    if case .cooldown(let until) = state {
      let quadFresh = (trackingResult?.confidence ?? 0) >= minConfidence
      if quadFresh { lastQuadSeenTime = now }

      if let lastSeen = lastQuadSeenTime, now - lastSeen >= absenceResetDuration {
        state = .idle
      } else if now >= until {
        state = .idle
      } else {
        return nil
      }
    }

    // Per-frame gate
    guard let quad = passesGate(trackingResult: trackingResult, pixelBuffer: pixelBuffer, now: now) else {
      if let result = trackingResult, result.confidence > 0 {
        lastQuadSeenTime = now
      }
      if case .armed = state {
        debugLog(now, "gate failed during armed window — reset to idle")
        state = .idle
      }
      driftHistory.removeAll()
      return nil
    }

    lastQuadSeenTime = now

    // Motion check
    let center = quad.center
    driftHistory.append((now, center))
    let cutoff: CFTimeInterval = now - (driftWindow * 2.0)
    driftHistory.removeAll { $0.t < cutoff }
    if !isMotionAcceptable(now: now) {
      state = .idle
      return nil
    }

    switch state {
    case .idle:
      debugLog(now, "gate PASSED — transition idle → armed")
      state = .armed(since: now)
      return nil

    case .armed(let since):
      let elapsed = now - since
      if elapsed >= armedDuration {
        #if DEBUG
        NSLog("[CoverDetect] ✅ FIRED after %.2fs held — emitting candidate", elapsed)
        #endif
        let candidate = CoverCandidate(
          quad: quad,
          pixelBuffer: pixelBuffer,
          frameTimestamp: now
        )
        state = .cooldown(until: now + cooldownDuration)
        driftHistory.removeAll()
        return candidate
      }
      debugLog(now, String(format: "armed — holding %.2fs / %.2fs", elapsed, armedDuration))
      return nil

    case .cooldown:
      return nil  // handled above
    }
  }

  private func debugLog(_ now: CFTimeInterval, _ message: String) {
    #if DEBUG
    if now - lastDebugLogTime >= debugLogInterval {
      NSLog("[CoverDetect] \(message)")
      lastDebugLogTime = now
    }
    #endif
  }

  func resetCooldown() {
    state = .idle
    driftHistory.removeAll()
    lastQuadSeenTime = nil
  }

  // MARK: - Per-frame gate

  private func passesGate(trackingResult: PageTrackingService.TrackingResult?,
                          pixelBuffer: CVPixelBuffer,
                          now: CFTimeInterval) -> PageTrackingService.DocumentQuad? {
    guard let result = trackingResult else {
      debugLog(now, "no tracking result (no quad)")
      return nil
    }
    guard result.confidence >= minConfidence else {
      debugLog(now, String(format: "reject: confidence %.2f < %.2f", result.confidence, minConfidence))
      return nil
    }

    let quad = result.quad

    // Convert normalized Vision coords → pixel-space edge lengths using the
    // actual buffer dimensions. Matches SelectionOverlayView.convert(), which
    // multiplies normalized.x by scaled image width and normalized.y by scaled
    // image height before drawing the cyan overlay. Without this scaling the
    // aspect ratio lies about the true shape of the detected rectangle.
    let bufferW = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
    let bufferH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

    let xs = [quad.topLeft.x, quad.topRight.x, quad.bottomLeft.x, quad.bottomRight.x]
    let ys = [quad.topLeft.y, quad.topRight.y, quad.bottomLeft.y, quad.bottomRight.y]
    guard let minX = xs.min(), let maxX = xs.max(),
          let minY = ys.min(), let maxY = ys.max() else { return nil }
    let bboxArea = (maxX - minX) * (maxY - minY)
    guard bboxArea >= minBBoxArea else {
      debugLog(now, String(format: "reject: area %.3f < %.3f", bboxArea, minBBoxArea))
      return nil
    }

    // Edge lengths in true pixel space.
    let topPx = hypot((quad.topRight.x - quad.topLeft.x) * bufferW,
                      (quad.topRight.y - quad.topLeft.y) * bufferH)
    let leftPx = hypot((quad.topLeft.x - quad.bottomLeft.x) * bufferW,
                       (quad.topLeft.y - quad.bottomLeft.y) * bufferH)
    let bottomPx = hypot((quad.bottomRight.x - quad.bottomLeft.x) * bufferW,
                         (quad.bottomRight.y - quad.bottomLeft.y) * bufferH)
    let rightPx = hypot((quad.topRight.x - quad.bottomRight.x) * bufferW,
                        (quad.topRight.y - quad.bottomRight.y) * bufferH)

    let longSide = max(topPx, leftPx)
    let shortSide = min(topPx, leftPx)
    guard shortSide > 1.0 else { return nil }
    let aspect = longSide / shortSide  // always >= 1.0, orientation-agnostic
    guard aspect >= minAspect, aspect <= maxAspect else {
      debugLog(now, String(format: "reject: aspect %.2f outside [%.2f..%.2f] (top=%.0fpx left=%.0fpx)",
                           aspect, minAspect, maxAspect, topPx, leftPx))
      return nil
    }

    let angles = interiorAngles(quad)
    let rightAngle = Double.pi / 2
    let meanDev = angles.map { abs($0 - rightAngle) }.reduce(0, +) / Double(angles.count)
    let rectScore = 1.0 - meanDev / rightAngle
    guard rectScore >= minRectangularity else {
      debugLog(now, String(format: "reject: rect %.3f < %.3f", rectScore, minRectangularity))
      return nil
    }

    guard parityWithin(topPx, bottomPx, maxRatio: maxSideParityRatio),
          parityWithin(leftPx, rightPx, maxRatio: maxSideParityRatio) else {
      debugLog(now, String(format: "reject: parity top=%.0f bot=%.0f left=%.0f right=%.0f",
                           topPx, bottomPx, leftPx, rightPx))
      return nil
    }

    debugLog(now, String(format: "✓ gate passed: aspect %.2f (long=%.0f short=%.0f) area=%.3f rect=%.2f",
                         aspect, longSide, shortSide, bboxArea, rectScore))
    return quad
  }

  private func parityWithin(_ a: CGFloat, _ b: CGFloat, maxRatio: CGFloat) -> Bool {
    let maxVal = max(a, b)
    guard maxVal > 0 else { return false }
    return abs(a - b) / maxVal < maxRatio
  }

  /// Interior angles at TL, TR, BR, BL in radians.
  private func interiorAngles(_ quad: PageTrackingService.DocumentQuad) -> [Double] {
    let corners = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
    var result: [Double] = []
    result.reserveCapacity(4)
    for i in 0..<4 {
      let prev = corners[(i + 3) % 4]
      let curr = corners[i]
      let next = corners[(i + 1) % 4]
      let v1 = CGPoint(x: prev.x - curr.x, y: prev.y - curr.y)
      let v2 = CGPoint(x: next.x - curr.x, y: next.y - curr.y)
      let dot = Double(v1.x * v2.x + v1.y * v2.y)
      let mag = Double(hypot(v1.x, v1.y) * hypot(v2.x, v2.y))
      guard mag > 1e-9 else { return [0, 0, 0, 0] }
      let cosAngle = max(-1.0, min(1.0, dot / mag))
      result.append(acos(cosAngle))
    }
    return result
  }

  private func isMotionAcceptable(now: CFTimeInterval) -> Bool {
    guard let current = driftHistory.last?.center else { return true }

    let ageFloor: CFTimeInterval = driftWindow * 0.8
    var oldest: CGPoint? = nil
    for entry in driftHistory {
      let age: CFTimeInterval = now - entry.t
      if age >= ageFloor {
        oldest = entry.center
        break
      }
    }

    guard let old = oldest else {
      return true  // Not enough history yet — be lenient.
    }

    let dx: CGFloat = current.x - old.x
    let dy: CGFloat = current.y - old.y
    return hypot(dx, dy) < maxCenterDrift
  }
}
