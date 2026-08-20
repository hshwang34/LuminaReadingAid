//
// HighlightGestureTracker.swift
//
// State machine that distinguishes quick-pinch (word lookup) from sustained-pinch-drag
// (underline highlight mode). Uses raw pinchDistance to bypass PinchTracker's 1-second
// cooldown, enabling accurate detection of pinch release during drag gestures.
//
// During highlighting, accumulates a trail of book-relative fingertip positions and
// auto-segments them into per-line strips by detecting downward movement on the page.
//

import CoreGraphics
import Foundation

final class HighlightGestureTracker {
  // MARK: - Public State

  private(set) var phase: HighlightGesturePhase = .idle
  private(set) var underlineSelection: UnderlineSelection?
  /// Camera-space fingertip stored during pinchStarted, for the start marker overlay.
  private(set) var startMarkerCamera: CGPoint?

  // MARK: - Configuration

  /// Seconds the pinch must be held before entering highlight mode.
  private let holdThreshold: TimeInterval = 0.3
  /// Normalized Vision distance below which a pinch is considered active.
  private let pinchThreshold: CGFloat = 0.09
  /// Normalized Vision distance above which a pinch is considered released (hysteresis).
  private let releaseThreshold: CGFloat = 0.12
  /// Minimum x-span of any trail line to be considered a valid selection.
  private let minimumTrailLength: CGFloat = 0.01

  // MARK: - Internal State

  private var pinchStartTime: TimeInterval = 0

  // MARK: - Public API

  /// Call each frame with the current hand tracking state.
  /// Returns the updated gesture phase.
  ///
  /// - Parameters:
  ///   - pinchDistance: Raw normalized distance between thumb tip and index PIP.
  ///   - fingerTipCamera: Index fingertip position in Vision camera coords (0–1).
  ///   - bookRelativePoint: Fingertip converted to book-relative coords. nil if no book detected.
  ///   - anchor: Current book center in camera coords. nil if no book detected.
  ///   - timestamp: Current frame timestamp.
  @discardableResult
  func update(
    pinchDistance: CGFloat?,
    fingerTipCamera: CGPoint?,
    bookRelativePoint: CGPoint?,
    anchor: CGPoint?,
    timestamp: TimeInterval
  ) -> HighlightGesturePhase {
    // During an active gesture, nil pinchDistance means tracking dropped — NOT a release.
    // Hold the current state until tracking returns.
    if pinchDistance == nil {
      switch phase {
      case .pinchStarted, .highlighting:
        return phase
      default:
        break
      }
    }

    let isPinched = (pinchDistance ?? 1.0) < pinchThreshold
    let isReleased = (pinchDistance ?? 1.0) > releaseThreshold

    switch phase {
    case .idle:
      if isPinched {
        phase = .pinchStarted(at: timestamp)
        pinchStartTime = timestamp
        startMarkerCamera = fingerTipCamera
      }

    case .pinchStarted:
      if isReleased {
        // Released before hold threshold — quick pinch for word lookup
        phase = .idle
        startMarkerCamera = nil
      } else if (timestamp - pinchStartTime) >= holdThreshold {
        // Held long enough — enter highlight mode
        if let point = bookRelativePoint, let center = anchor {
          phase = .highlighting
          underlineSelection = UnderlineSelection(
            anchor: center,
            lines: [UnderlineTrailLine(points: [point])]
          )
          startMarkerCamera = nil
        }
        // If no book detected yet, stay in pinchStarted and wait
      }

    case .highlighting:
      if isReleased {
        // Pinch released — check if selection is valid
        if let sel = underlineSelection, sel.isValid {
          phase = .completed
        } else {
          phase = .idle
          underlineSelection = nil
        }
        startMarkerCamera = nil
      } else {
        // Still pinched — accumulate trail point
        if let point = bookRelativePoint, let center = anchor {
          appendTrailPoint(point)
          underlineSelection?.anchor = center
        }
      }

    case .completed:
      // External code should call reset() after reading the selection
      break
    }

    return phase
  }

  /// Resets the tracker to idle. Call after processing a completed selection.
  func reset() {
    phase = .idle
    underlineSelection = nil
    startMarkerCamera = nil
    pinchStartTime = 0
  }

  // MARK: - Private

  private func appendTrailPoint(_ point: CGPoint) {
    guard underlineSelection != nil, !underlineSelection!.lines.isEmpty else { return }

    let currentLineIndex = underlineSelection!.lines.count - 1
    let currentLine = underlineSelection!.lines[currentLineIndex]

    // Detect line break: new point's y is significantly below current line's y center.
    // In Vision coords, "down the page" = decreasing y.
    if !currentLine.points.isEmpty {
      let yDrop = currentLine.yCenter - point.y
      if yDrop > kLineBreakThreshold {
        // Start a new line
        underlineSelection!.lines.append(UnderlineTrailLine(points: [point]))
        return
      }
    }

    // Append to current line
    underlineSelection!.lines[currentLineIndex].points.append(point)
  }
}
