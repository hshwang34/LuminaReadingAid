//
// PageProgressTrackerTests.swift
//
// Unit tests for the debouncer logic that turns noisy OCR readings into confirmed page
// transitions. All pure Swift — no Vision dependency, so these run fast.
//

import XCTest
@testable import CameraAccess

final class PageProgressTrackerTests: XCTestCase {

  /// Builds a monotonic clock so the tests don't depend on real Date math.
  private func tick(_ base: Date, _ offset: TimeInterval) -> Date {
    base.addingTimeInterval(offset)
  }

  // MARK: - First commit

  func testFirstCommitRequiresThreeAgreeingObservations() {
    let tracker = PageProgressTracker()
    let base = Date(timeIntervalSince1970: 0)
    XCTAssertNil(tracker.observe(value: 37, now: tick(base, 0)))
    XCTAssertNil(tracker.observe(value: 37, now: tick(base, 30)))
    let commit = tracker.observe(value: 37, now: tick(base, 60))
    XCTAssertEqual(commit?.page, 37)
    XCTAssertTrue(commit?.transitioned ?? false)
  }

  func testFirstCommitToleratesAdjacentPagesInSpread() {
    // A two-page spread legitimately shows both page numbers; commit the higher one.
    let tracker = PageProgressTracker()
    let base = Date(timeIntervalSince1970: 0)
    XCTAssertNil(tracker.observe(value: 36, now: tick(base, 0)))
    XCTAssertNil(tracker.observe(value: 37, now: tick(base, 30)))
    let commit = tracker.observe(value: 37, now: tick(base, 60))
    XCTAssertEqual(commit?.page, 37)
  }

  // MARK: - Spurious jumps

  func testSingleSpuriousJumpIsRejected() {
    let tracker = PageProgressTracker()
    let base = Date(timeIntervalSince1970: 0)
    _ = tracker.observe(value: 37, now: tick(base, 0))
    _ = tracker.observe(value: 37, now: tick(base, 30))
    _ = tracker.observe(value: 37, now: tick(base, 60))  // commits 37
    // One bad frame:
    let badCommit = tracker.observe(value: 128, now: tick(base, 90))
    XCTAssertNil(badCommit, "A single far-away observation must not commit")
    XCTAssertEqual(tracker.currentPage, 37)
  }

  func testSustainedJumpCommitsNonAdjacent() {
    let tracker = PageProgressTracker()
    let base = Date(timeIntervalSince1970: 0)
    _ = tracker.observe(value: 37, now: tick(base, 0))
    _ = tracker.observe(value: 37, now: tick(base, 30))
    _ = tracker.observe(value: 37, now: tick(base, 60))  // commits 37
    // Five consecutive sightings of 128 — user really did skip ahead.
    _ = tracker.observe(value: 128, now: tick(base, 90))
    _ = tracker.observe(value: 128, now: tick(base, 120))
    _ = tracker.observe(value: 128, now: tick(base, 150))
    _ = tracker.observe(value: 128, now: tick(base, 180))
    let commit = tracker.observe(value: 128, now: tick(base, 210))
    XCTAssertEqual(commit?.page, 128)
    XCTAssertTrue(commit?.transitioned ?? false)
  }

  // MARK: - Adjacent transitions

  func testAdjacentTransitionCommitsWithThreeObservations() {
    let tracker = PageProgressTracker()
    let base = Date(timeIntervalSince1970: 0)
    _ = tracker.observe(value: 37, now: tick(base, 0))
    _ = tracker.observe(value: 37, now: tick(base, 30))
    _ = tracker.observe(value: 37, now: tick(base, 60))  // commits 37
    _ = tracker.observe(value: 38, now: tick(base, 90))
    _ = tracker.observe(value: 38, now: tick(base, 120))
    let commit = tracker.observe(value: 38, now: tick(base, 150))
    XCTAssertEqual(commit?.page, 38)
    XCTAssertEqual(tracker.currentPage, 38)
  }

  func testBackwardAdjacentTransitionAlsoCommits() {
    // Re-reading — user flipped backward; tracker should still follow.
    let tracker = PageProgressTracker()
    let base = Date(timeIntervalSince1970: 0)
    _ = tracker.observe(value: 42, now: tick(base, 0))
    _ = tracker.observe(value: 42, now: tick(base, 30))
    _ = tracker.observe(value: 42, now: tick(base, 60))
    _ = tracker.observe(value: 41, now: tick(base, 90))
    _ = tracker.observe(value: 41, now: tick(base, 120))
    let commit = tracker.observe(value: 41, now: tick(base, 150))
    XCTAssertEqual(commit?.page, 41)
  }

  // MARK: - Pace

  func testPagesPerMinuteIgnoresRereads() {
    // Forward from 37→42 at 30s/page should yield 2 pg/min.
    let tracker = PageProgressTracker()
    let base = Date(timeIntervalSince1970: 0)
    _ = tracker.observe(value: 37, now: tick(base, 0))
    _ = tracker.observe(value: 37, now: tick(base, 30))
    _ = tracker.observe(value: 37, now: tick(base, 60))
    _ = tracker.observe(value: 38, now: tick(base, 90))
    _ = tracker.observe(value: 38, now: tick(base, 120))
    _ = tracker.observe(value: 38, now: tick(base, 150))
    let pace = tracker.pagesPerMinute(now: tick(base, 150))
    XCTAssertNotNil(pace)
    if let pace { XCTAssertGreaterThan(pace, 0) }
  }

  // MARK: - Reset

  func testResetClearsState() {
    let tracker = PageProgressTracker()
    let base = Date(timeIntervalSince1970: 0)
    _ = tracker.observe(value: 37, now: tick(base, 0))
    _ = tracker.observe(value: 37, now: tick(base, 30))
    _ = tracker.observe(value: 37, now: tick(base, 60))
    XCTAssertEqual(tracker.currentPage, 37)
    tracker.reset()
    XCTAssertNil(tracker.currentPage)
    XCTAssertNil(tracker.pagesPerMinute(now: tick(base, 120)))
  }
}

// MARK: - Page Number Parser

final class PageNumberParseTests: XCTestCase {

  func testPlainDigitsAccepted() {
    XCTAssertEqual(PageNumberDetector.parsePageNumber("37"), 37)
    XCTAssertEqual(PageNumberDetector.parsePageNumber("1"), 1)
    XCTAssertEqual(PageNumberDetector.parsePageNumber("999"), 999)
  }

  func testDecorativeSurroundsStripped() {
    XCTAssertEqual(PageNumberDetector.parsePageNumber("— 238 —"), 238)
    XCTAssertEqual(PageNumberDetector.parsePageNumber("· 12 ·"), 12)
    XCTAssertEqual(PageNumberDetector.parsePageNumber("| 404 |"), 404)
  }

  func testWordsRejected() {
    XCTAssertNil(PageNumberDetector.parsePageNumber("Chapter 12"))
    XCTAssertNil(PageNumberDetector.parsePageNumber("page 12"))
    XCTAssertNil(PageNumberDetector.parsePageNumber("12a"))
  }

  func testYearsRejected() {
    // Four-digit years in the publication range must be rejected to avoid committing
    // copyright pages and running headers.
    XCTAssertNil(PageNumberDetector.parsePageNumber("1984"))
    XCTAssertNil(PageNumberDetector.parsePageNumber("2015"))
    XCTAssertNil(PageNumberDetector.parsePageNumber("1066"))
  }

  func testFiveDigitRejected() {
    XCTAssertNil(PageNumberDetector.parsePageNumber("10000"))
  }

  func testZeroRejected() {
    XCTAssertNil(PageNumberDetector.parsePageNumber("0"))
  }

  func testEmptyRejected() {
    XCTAssertNil(PageNumberDetector.parsePageNumber(""))
    XCTAssertNil(PageNumberDetector.parsePageNumber("—"))
  }
}

// MARK: - ROI Learner

final class PageROILearnerTests: XCTestCase {

  private func candidate(
    value: Int, rect: CGRect, side: PageColumnSide? = nil
  ) -> PageNumberCandidate {
    PageNumberCandidate(value: value, columnRect: rect, side: side)
  }

  func testThreeConsistentCandidatesCommit() {
    let learner = PageROILearner()
    // Three candidates, all near (0.45, 0.05, 0.1, 0.05), with consecutive page values.
    XCTAssertNil(learner.observe([candidate(value: 37, rect: CGRect(x: 0.45, y: 0.05, width: 0.1, height: 0.05))]))
    XCTAssertNil(learner.observe([candidate(value: 38, rect: CGRect(x: 0.46, y: 0.05, width: 0.1, height: 0.05))]))
    let roi = learner.observe([candidate(value: 39, rect: CGRect(x: 0.45, y: 0.055, width: 0.1, height: 0.05))])
    XCTAssertNotNil(roi)
    XCTAssertEqual(roi?.missStreak, 0)
  }

  func testScatteredCandidatesDoNotCommit() {
    let learner = PageROILearner()
    XCTAssertNil(learner.observe([candidate(value: 37, rect: CGRect(x: 0.1, y: 0.05, width: 0.05, height: 0.03))]))
    XCTAssertNil(learner.observe([candidate(value: 100, rect: CGRect(x: 0.8, y: 0.05, width: 0.05, height: 0.03))]))
    XCTAssertNil(learner.observe([candidate(value: 5, rect: CGRect(x: 0.5, y: 0.9, width: 0.05, height: 0.03))]))
  }

  func testSpreadSidesPoolViaSpineMirror() {
    // Same frame: left page 36 with rect at left-edge of left column (0.05, 0.05, 0.08, 0.03),
    // right page 37 with rect at right-edge of right column (0.87, 0.05, 0.08, 0.03).
    // After mirroring the right rect across the spine → (0.05, 0.05, 0.08, 0.03), the two
    // are co-located and form a cluster of 2 from a single frame.
    let learner = PageROILearner()
    let leftRect = CGRect(x: 0.05, y: 0.05, width: 0.08, height: 0.03)
    let rightRect = CGRect(x: 0.87, y: 0.05, width: 0.08, height: 0.03)
    // Frame 1: two readings, one from each page. Not enough yet (needs 3).
    XCTAssertNil(learner.observe([
      candidate(value: 36, rect: leftRect, side: .left),
      candidate(value: 37, rect: rightRect, side: .right),
    ]))
    // Frame 2: user flipped forward. Left should now say 38, right 39.
    let roi = learner.observe([
      candidate(value: 38, rect: leftRect, side: .left),
    ])
    // Three mutually-consistent mirrored candidates (36,37,38 all near mirrored-left rect).
    XCTAssertNotNil(roi)
    // ROI is stored in left-page coord space.
    XCTAssertEqual(roi?.rect.minX ?? -1, 0.05, accuracy: 0.01)
  }
}
