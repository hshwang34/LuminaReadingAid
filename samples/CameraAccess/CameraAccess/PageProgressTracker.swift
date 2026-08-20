//
// PageProgressTracker.swift
//
// Debouncer that turns a noisy stream of raw page-number observations into confirmed
// page transitions. Required because a single OCR glitch (e.g. a chapter number briefly
// misread as "128" while the user is actually on page 37) must not corrupt the reading
// session. Observations are only committed when the same page (or an adjacent page) is
// seen a sustained number of times.
//
// Pure Swift, no Vision — unit-testable against an injected clock.
//

import Foundation

/// A single observation from the detector: the parsed page value and its timestamp.
struct PageObservation: Equatable {
  let value: Int
  let at: Date
}

/// Result of observing a new candidate.
struct PageCommit: Equatable {
  /// The committed page number (may be unchanged from the previous commit).
  let page: Int
  /// True when this commit is a transition to a different page than the previous one.
  let transitioned: Bool
}

final class PageProgressTracker {

  // MARK: - Configuration

  /// Observations needed inside the sliding window to commit the first page, or to
  /// commit an **adjacent** transition (+1/+2). Intentionally small because normal page
  /// turns are common and legitimate.
  let adjacentCommitCount = 3

  /// Observations needed to commit a **non-adjacent** jump (e.g. 37 → 128). Larger,
  /// so a one-off misread can't derail the session.
  let nonAdjacentCommitCount = 5

  /// Size of the sliding window used for adjacent-commit voting.
  let windowSize = 5

  /// A transition is "adjacent" if the new page is within this many pages of the current.
  /// 2 allows natural skipping (user flips two pages at once) without demanding the stricter
  /// non-adjacent threshold.
  let adjacentDelta = 2

  /// Window over which pages-per-minute is averaged. A longer window smooths jitter at the
  /// cost of slower response to pace changes; 3 min is a reasonable default for reading.
  let paceWindow: TimeInterval = 180

  // MARK: - State

  private(set) var currentPage: Int?
  private var observations: [PageObservation] = []
  private var transitions: [PageObservation] = []  // committed page transitions

  // MARK: - Public API

  /// Observe a freshly parsed page value at `now`. Returns a `PageCommit` when the
  /// observation moves the tracker's committed state (first page, or page change);
  /// returns nil while still debouncing.
  @discardableResult
  func observe(value: Int, now: Date) -> PageCommit? {
    let obs = PageObservation(value: value, at: now)
    observations.append(obs)
    if observations.count > windowSize * 2 {
      observations.removeFirst(observations.count - windowSize * 2)
    }

    // Not yet committed — wait for the first stable reading.
    guard let committed = currentPage else {
      if let firstPage = firstStablePage() {
        currentPage = firstPage
        transitions.append(PageObservation(value: firstPage, at: now))
        return PageCommit(page: firstPage, transitioned: true)
      }
      return nil
    }

    // Already committed — check the recent window for a new stable page.
    if let newPage = nextStablePage(current: committed) {
      currentPage = newPage
      transitions.append(PageObservation(value: newPage, at: now))
      return PageCommit(page: newPage, transitioned: newPage != committed)
    }
    return nil
  }

  /// Pages-per-minute based on committed transitions in the last `paceWindow` seconds.
  /// Returns nil if fewer than 2 transitions are available (can't compute a rate).
  func pagesPerMinute(now: Date) -> Double? {
    let cutoff = now.addingTimeInterval(-paceWindow)
    let recent = transitions.filter { $0.at >= cutoff }
    guard recent.count >= 2 else { return nil }
    guard let first = recent.first, let last = recent.last else { return nil }
    let pageDelta = Double(last.value - first.value)
    let seconds = last.at.timeIntervalSince(first.at)
    guard seconds > 0 else { return nil }
    // Only count forward progress; backward jumps (re-read) shouldn't inflate or deflate
    // the pace metric artificially. Return nil for negative deltas.
    guard pageDelta > 0 else { return nil }
    return pageDelta / (seconds / 60.0)
  }

  // Reset — call when the session ends or switches books.
  func reset() {
    currentPage = nil
    observations.removeAll(keepingCapacity: true)
    transitions.removeAll(keepingCapacity: true)
  }

  // MARK: - Voting

  /// First commit: look for any page value that appears at least `adjacentCommitCount`
  /// times in the most recent `windowSize` observations, tolerating ±1 (two-page spread
  /// legitimately yields consecutive numbers). Returns the highest such value — the
  /// "reading frontier".
  private func firstStablePage() -> Int? {
    let recent = Array(observations.suffix(windowSize))
    guard recent.count >= adjacentCommitCount else { return nil }

    // Bucket ±1 neighbors together by canonical (lower) value.
    var votes: [Int: Int] = [:]
    for obs in recent {
      votes[obs.value, default: 0] += 1
    }

    // Look for any page where [p] + [p-1] + [p+1] ≥ threshold, then return the highest p
    // that qualifies (prefer the leading edge of the spread).
    var best: Int?
    for (page, _) in votes {
      let total = (votes[page] ?? 0) + (votes[page - 1] ?? 0) + (votes[page + 1] ?? 0)
      if total >= adjacentCommitCount {
        if best == nil || page > best! { best = page }
      }
    }
    return best
  }

  /// Subsequent commits: find a new stable page different from `current`.
  /// Adjacent transitions need `adjacentCommitCount` in the window; non-adjacent need
  /// `nonAdjacentCommitCount` consecutive observations.
  private func nextStablePage(current: Int) -> Int? {
    // 1. Adjacent-path: check the sliding window.
    let recent = Array(observations.suffix(windowSize))
    var counts: [Int: Int] = [:]
    for obs in recent where obs.value != current {
      if abs(obs.value - current) <= adjacentDelta {
        counts[obs.value, default: 0] += 1
      }
    }
    if let (page, _) = counts.max(by: { $0.value < $1.value }),
       (counts[page] ?? 0) >= adjacentCommitCount {
      return page
    }

    // 2. Non-adjacent path: require `nonAdjacentCommitCount` consecutive matching
    // observations of the same far-away value. We check the tail of the history.
    let tail = observations.suffix(nonAdjacentCommitCount)
    guard tail.count == nonAdjacentCommitCount else { return nil }
    let firstValue = tail.first!.value
    guard abs(firstValue - current) > adjacentDelta else { return nil }
    if tail.allSatisfy({ $0.value == firstValue }) {
      return firstValue
    }
    return nil
  }
}
