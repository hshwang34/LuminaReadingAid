//
// PageNumberDetector.swift
//
// Finds the current page number from a still frame of a book. Runs in one of two modes:
//
//   • Learning — scans thin strips at the top and bottom of each detected page column,
//     OCRs them, and returns every numeric token it finds. The caller feeds these
//     candidates into `PageROILearner` until a stable location is confirmed.
//
//   • Locked  — given a previously learned `PageNumberROI`, OCRs only that tight rect.
//     Roughly an order of magnitude cheaper than learning mode.
//
// Both modes use the existing `OrientedCrop.extractUpright(from:)` to get tilt-corrected
// upright UIImages, so skewed or tilted books are handled by the same machinery that
// already powers passage extraction.
//

import Vision
import CoreGraphics
import UIKit

// MARK: - Types

/// Internal tag describing which half of a spread a candidate came from. Never stored;
/// only used by the learner to mirror right-side rects into the canonical left-page
/// coordinate space before clustering.
enum PageColumnSide {
  case left, right
}

/// A parsed page-number candidate plus enough geometry to learn its ROI.
struct PageNumberCandidate: Equatable {
  /// Parsed integer value of the detected digits.
  let value: Int
  /// Location of the digit rect in **column-normalized** coordinates — (0,0) top-left,
  /// (1,1) bottom-right of whichever column the candidate was read from. This is the
  /// coordinate space `PageNumberROI.rect` is stored in after mirroring.
  let columnRect: CGRect
  /// Internal: which column this candidate came from. Used by the learner to mirror
  /// right-column rects into left-column space before clustering.
  let side: PageColumnSide?

  static func == (lhs: PageNumberCandidate, rhs: PageNumberCandidate) -> Bool {
    lhs.value == rhs.value && lhs.columnRect == rhs.columnRect && lhs.side == rhs.side
  }
}

// MARK: - Detector

final class PageNumberDetector {

  /// Fraction of column height to scan at the top and at the bottom in learning mode.
  /// Page numbers almost always sit in these margins; scanning the middle would mostly
  /// return body text.
  private let marginFraction: CGFloat = 0.10

  /// Expand the learned ROI by this much on each axis before cropping, to absorb drift
  /// between quads and small changes in how the book is held.
  private let lockedRectPadding: CGFloat = 0.20

  /// Shared GPU CIContext — mirrors the pattern in PassageExtractionService.
  private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

  /// Reusable OCR request. Language correction is **off** — we want raw digits, not
  /// an autocorrected English word; "lol" getting autocorrected from "101" was a real
  /// failure mode in internal testing.
  private let textRequest: VNRecognizeTextRequest = {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false
    req.recognitionLanguages = ["en-US"]
    return req
  }()

  // MARK: - Learning Mode

  /// Scan the top and bottom margins of each detected column and return every plausible
  /// page-number candidate. Caller feeds these into `PageROILearner` across multiple
  /// frames to converge on a stable ROI.
  func scanLearning(image: UIImage, quad: PageTrackingService.DocumentQuad, axes: BookAxisBasis) -> [PageNumberCandidate] {
    let layout = PageColumnLayout(
      topLeft: quad.topLeft,
      topRight: quad.topRight,
      bottomLeft: quad.bottomLeft,
      bottomRight: quad.bottomRight,
      axes: axes
    )

    var candidates: [PageNumberCandidate] = []

    switch layout.mode {
    case .singleColumn:
      if let column = layout.leftColumn {
        candidates.append(contentsOf: scanColumnMargins(image: image, column: column, side: nil))
      }
    case .twoColumn:
      if let left = layout.leftColumn {
        candidates.append(contentsOf: scanColumnMargins(image: image, column: left, side: .left))
      }
      if let right = layout.rightColumn {
        candidates.append(contentsOf: scanColumnMargins(image: image, column: right, side: .right))
      }
    }

    return candidates
  }

  /// Mirror a right-column rect into the canonical left-page coordinate space by
  /// reflecting across x = 0.5. Leaves left-side and unsided rects untouched.
  static func mirrorToLeftPageSpace(_ candidate: PageNumberCandidate) -> PageNumberCandidate {
    guard candidate.side == .right else { return candidate }
    let r = candidate.columnRect
    let mirrored = CGRect(x: 1 - r.minX - r.width, y: r.minY, width: r.width, height: r.height)
    return PageNumberCandidate(value: candidate.value, columnRect: mirrored, side: candidate.side)
  }

  // MARK: - Locked Mode

  /// OCR the tight learned ROI on every visible page, and return the highest-valued
  /// digit found (the "reading frontier"). On a two-page spread we scan both the left
  /// column with `roi.rect` and the right column with the mirrored rect. On a single
  /// page we scan just the one column. Returns nil if nothing parses — the caller
  /// tracks miss streaks and restarts learning after enough consecutive failures.
  func scanLocked(
    image: UIImage,
    quad: PageTrackingService.DocumentQuad,
    axes: BookAxisBasis,
    roi: PageNumberROI
  ) -> PageNumberCandidate? {
    let layout = PageColumnLayout(
      topLeft: quad.topLeft,
      topRight: quad.topRight,
      bottomLeft: quad.bottomLeft,
      bottomRight: quad.bottomRight,
      axes: axes
    )

    let leftRect = paddedRect(roi.rect)
    let rightRect = paddedRect(mirrorRectAcrossSpine(roi.rect))

    var hits: [PageNumberCandidate] = []
    switch layout.mode {
    case .singleColumn:
      if let column = layout.leftColumn,
         let hit = ocrColumnRect(image: image, column: column, columnRect: leftRect, side: nil) {
        hits.append(hit)
      }
    case .twoColumn:
      if let left = layout.leftColumn,
         let hit = ocrColumnRect(image: image, column: left, columnRect: leftRect, side: .left) {
        hits.append(hit)
      }
      if let right = layout.rightColumn,
         let hit = ocrColumnRect(image: image, column: right, columnRect: rightRect, side: .right) {
        hits.append(hit)
      }
    }

    // Prefer the higher of the two values on a spread — that's the reading frontier.
    // If both sides agree off-by-one we've implicitly cross-validated the ROI.
    return hits.max(by: { $0.value < $1.value })
  }

  /// Mirror a column-local rect across x = 0.5 so it can be applied to the facing page.
  private func mirrorRectAcrossSpine(_ rect: CGRect) -> CGRect {
    CGRect(x: 1 - rect.minX - rect.width, y: rect.minY, width: rect.width, height: rect.height)
  }

  // MARK: - Debug Introspection

  /// Returns the oriented crop(s) this detector would OCR for the given quad, without
  /// actually running OCR. Used by the debug overlay so the user can visually confirm
  /// the scan regions are where they should be.
  func debugScanCrops(
    quad: PageTrackingService.DocumentQuad,
    axes: BookAxisBasis,
    roi: PageNumberROI?
  ) -> [OrientedCrop] {
    let layout = PageColumnLayout(
      topLeft: quad.topLeft,
      topRight: quad.topRight,
      bottomLeft: quad.bottomLeft,
      bottomRight: quad.bottomRight,
      axes: axes
    )

    var out: [OrientedCrop] = []

    if let roi {
      // Locked mode: show the padded ROI on every visible column.
      let leftRect = paddedRect(roi.rect)
      let rightRect = paddedRect(mirrorRectAcrossSpine(roi.rect))
      switch layout.mode {
      case .singleColumn:
        if let col = layout.leftColumn, let sub = subCrop(of: col, columnRect: leftRect) {
          out.append(sub)
        }
      case .twoColumn:
        if let col = layout.leftColumn, let sub = subCrop(of: col, columnRect: leftRect) {
          out.append(sub)
        }
        if let col = layout.rightColumn, let sub = subCrop(of: col, columnRect: rightRect) {
          out.append(sub)
        }
      }
      return out
    }

    // Learning mode: show the top and bottom margin strips on every visible column.
    let topRect = CGRect(x: 0, y: 0, width: 1, height: marginFraction)
    let bottomRect = CGRect(x: 0, y: 1 - marginFraction, width: 1, height: marginFraction)
    let columns: [OrientedCrop] = {
      switch layout.mode {
      case .singleColumn: return [layout.leftColumn].compactMap { $0 }
      case .twoColumn: return [layout.leftColumn, layout.rightColumn].compactMap { $0 }
      }
    }()
    for column in columns {
      for strip in [topRect, bottomRect] {
        if let sub = subCrop(of: column, columnRect: strip) {
          out.append(sub)
        }
      }
    }
    return out
  }

  // MARK: - Private: scanning a column

  /// Scan the top and bottom margin strips of a column in learning mode.
  private func scanColumnMargins(
    image: UIImage,
    column: OrientedCrop,
    side: PageColumnSide?
  ) -> [PageNumberCandidate] {
    let topRect = CGRect(x: 0, y: 0, width: 1, height: marginFraction)
    let bottomRect = CGRect(x: 0, y: 1 - marginFraction, width: 1, height: marginFraction)

    var out: [PageNumberCandidate] = []
    for stripRect in [topRect, bottomRect] {
      guard let sub = subCrop(of: column, columnRect: stripRect) else { continue }
      guard let upright = sub.extractUpright(from: image) else { continue }
      let strips = ocrDigitTokens(in: upright)
      for (value, relRect) in strips {
        // Convert strip-relative rect → column-relative rect.
        let colRect = mapStripRect(relRect, stripInColumn: stripRect)
        out.append(PageNumberCandidate(value: value, columnRect: colRect, side: side))
      }
    }
    return out
  }

  /// OCR a single known ROI within a column.
  private func ocrColumnRect(
    image: UIImage,
    column: OrientedCrop,
    columnRect: CGRect,
    side: PageColumnSide?
  ) -> PageNumberCandidate? {
    guard let sub = subCrop(of: column, columnRect: columnRect) else { return nil }
    guard let upright = sub.extractUpright(from: image) else { return nil }
    let hits = ocrDigitTokens(in: upright)
    // The locked crop should really only have one number in it. Pick whichever has the
    // largest rect area — most prominent digits are typically the page number.
    guard let best = hits.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) else {
      return nil
    }
    return PageNumberCandidate(value: best.0, columnRect: columnRect, side: side)
  }

  // MARK: - Private: OCR + numeric filter

  /// Runs the text recognition request on `image` and returns all tokens that parse as
  /// plausible page numbers, along with their bounding rect in strip-normalized
  /// (0–1, Vision y-up) coordinates.
  private func ocrDigitTokens(in image: UIImage) -> [(Int, CGRect)] {
    guard let cgImage = image.cgImage else { return [] }
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
      try handler.perform([textRequest])
    } catch {
      return []
    }
    guard let observations = textRequest.results else { return [] }

    var results: [(Int, CGRect)] = []
    for obs in observations {
      guard let candidate = obs.topCandidates(1).first else { continue }
      let raw = candidate.string.trimmingCharacters(in: .whitespaces)
      if let value = Self.parsePageNumber(raw) {
        results.append((value, obs.boundingBox))
      }
    }
    return results
  }

  // MARK: - Numeric filter (testable)

  /// Decide whether `raw` is a plausible page-number token. Pages are short integers
  /// with no letters attached (so "Chapter 12" is rejected), not four-digit years
  /// (so "1984" is rejected), and ≤ 9999 (real books never exceed this).
  static func parsePageNumber(_ raw: String) -> Int? {
    // Strip common decorative surrounds: em-dashes, spaces, pipes, bullets.
    let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "—–-·• |\t"))
    // Must be all digits after stripping.
    guard !trimmed.isEmpty else { return nil }
    guard trimmed.allSatisfy({ $0.isNumber }) else { return nil }
    guard trimmed.count <= 4 else { return nil }
    guard let value = Int(trimmed) else { return nil }
    guard value > 0 else { return nil }
    // Filter years: a 4-digit value in the publication-year range is almost always a
    // copyright notice or header reference, not a page number. Real books with > 1000
    // pages exist but are extreme edge cases; we accept them only below 1000.
    if trimmed.count == 4 && value >= 1000 && value <= 2100 { return nil }
    return value
  }

  // MARK: - Private: sub-crops inside a column

  /// Build an OrientedCrop covering a rectangle inside `column`, where the rectangle is
  /// given in column-normalized (0,0=top-left, 1,1=bottom-right, y-down) coordinates.
  /// Returns nil for degenerate rects.
  private func subCrop(of column: OrientedCrop, columnRect rect: CGRect) -> OrientedCrop? {
    let clamped = CGRect(
      x: max(0, rect.minX),
      y: max(0, rect.minY),
      width: min(1 - max(0, rect.minX), rect.width),
      height: min(1 - max(0, rect.minY), rect.height)
    )
    guard clamped.width > 0.005, clamped.height > 0.005 else { return nil }

    let W = column.size.width
    let H = column.size.height
    // Local book-axis offset from column center to sub-crop center (book-axis is y-up).
    let localX = (clamped.midX - 0.5) * W
    let localY = (0.5 - clamped.midY) * H  // y flip: rect.midY=0 is top (book-axis +y)

    // Apply the (possibly non-orthogonal) basis transform from book space to camera space,
    // using the same axes as the column crop.
    let h = column.axes.horizontal
    let v = column.axes.vertical
    let cameraCenter = CGPoint(
      x: column.center.x + localX * h.x + localY * v.x,
      y: column.center.y + localX * h.y + localY * v.y
    )

    return OrientedCrop(
      center: cameraCenter,
      size: CGSize(width: W * clamped.width, height: H * clamped.height),
      axes: column.axes
    )
  }

  /// Map an OCR observation rect from strip-normalized Vision coords (y-up, 0..1 within
  /// the extracted strip image) into column-normalized y-down coords (0..1 within the
  /// full column), given where the strip sits inside the column.
  private func mapStripRect(_ stripRect: CGRect, stripInColumn: CGRect) -> CGRect {
    // Vision observation y is bottom-up; convert to top-down within the strip.
    let topDownMinY = 1 - (stripRect.minY + stripRect.height)
    let cx = stripInColumn.minX + stripRect.midX * stripInColumn.width
    let cy = stripInColumn.minY + (topDownMinY + stripRect.height / 2) * stripInColumn.height
    let w = stripRect.width * stripInColumn.width
    let h = stripRect.height * stripInColumn.height
    return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
  }

  /// Expand an ROI rect by `lockedRectPadding` on each axis and clamp to [0,1].
  private func paddedRect(_ rect: CGRect) -> CGRect {
    let padW = rect.width * lockedRectPadding
    let padH = rect.height * lockedRectPadding
    let x = max(0, rect.minX - padW)
    let y = max(0, rect.minY - padH)
    let w = min(1 - x, rect.width + padW * 2)
    let h = min(1 - y, rect.height + padH * 2)
    return CGRect(x: x, y: y, width: w, height: h)
  }
}

// MARK: - ROI Learner

/// Collects candidates across multiple learning-mode scans and commits a `PageNumberROI`
/// once three of them agree on both **location** (≥60% IoU between rects) and **value**
/// (within a few pages of each other — real page turns during learning are fine).
final class PageROILearner {
  /// Minimum IoU between two candidate rects for them to count as "same location".
  let iouThreshold: CGFloat = 0.6

  /// Max absolute page-number difference for learning-phase candidates to count as
  /// consistent. 5 allows the user to turn a few pages while learning.
  let valueDelta = 5

  /// Commits require this many mutually-consistent candidates.
  let requiredMatches = 3

  private var buffer: [PageNumberCandidate] = []

  /// Feed a batch of candidates from a single frame. Returns a committed ROI when the
  /// buffered set first contains `requiredMatches` mutually-consistent candidates.
  ///
  /// Right-side candidates are mirrored across the spine into canonical left-page
  /// coordinates before clustering — so both columns of a two-page spread contribute
  /// to the same cluster. This halves learning time on spreads compared to tracking
  /// each side independently, and bakes in the symmetry assumption used by the
  /// locked-mode scan.
  func observe(_ newCandidates: [PageNumberCandidate]) -> PageNumberROI? {
    let normalized = newCandidates.map(PageNumberDetector.mirrorToLeftPageSpace)
    buffer.append(contentsOf: normalized)
    // Keep the buffer small — we only need the most recent handful.
    if buffer.count > 40 {
      buffer.removeFirst(buffer.count - 40)
    }

    for anchor in buffer.reversed() {
      let cluster = buffer.filter { other in
        guard abs(other.value - anchor.value) <= valueDelta else { return false }
        return rectIoU(anchor.columnRect, other.columnRect) >= iouThreshold
      }
      if cluster.count >= requiredMatches {
        let meanRect = averageRect(cluster.map(\.columnRect))
        buffer.removeAll(keepingCapacity: true)
        return PageNumberROI(rect: meanRect, missStreak: 0)
      }
    }
    return nil
  }

  func reset() {
    buffer.removeAll(keepingCapacity: true)
  }

  // MARK: - Geometry helpers

  private func rectIoU(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let inter = a.intersection(b)
    guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
    let interArea = inter.width * inter.height
    let unionArea = a.width * a.height + b.width * b.height - interArea
    guard unionArea > 0 else { return 0 }
    return interArea / unionArea
  }

  private func averageRect(_ rects: [CGRect]) -> CGRect {
    guard !rects.isEmpty else { return .zero }
    let n = CGFloat(rects.count)
    let x = rects.map(\.minX).reduce(0, +) / n
    let y = rects.map(\.minY).reduce(0, +) / n
    let w = rects.map(\.width).reduce(0, +) / n
    let h = rects.map(\.height).reduce(0, +) / n
    return CGRect(x: x, y: y, width: w, height: h)
  }
}
