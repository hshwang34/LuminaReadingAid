//
// ThinkStripperTests.swift
//
// The stripper is the only thing standing between a model that ignores /no_think and
// a voice that reads its own reasoning aloud. The hard cases are all about tags
// split across token boundaries, because tokens do not respect tag edges.
//

import XCTest
@testable import CameraAccess

final class ThinkStripperTests: XCTestCase {

  private func run(_ chunks: [String]) -> String {
    var stripper = ThinkStripper()
    return chunks.map { stripper.consume($0) }.joined()
  }

  func testPassesPlainTextThrough() {
    XCTAssertEqual(run(["Divine means ", "godlike."]), "Divine means godlike.")
  }

  func testStripsAWholeThinkBlock() {
    XCTAssertEqual(
      run(["<think>reasoning about senses</think>Divine means godlike."]),
      "Divine means godlike."
    )
  }

  func testStripsBlockSplitAcrossChunks() {
    XCTAssertEqual(
      run(["<th", "ink>internal ", "monologue</th", "ink>The answer."]),
      "The answer."
    )
  }

  func testHoldsPartialTagThatTurnsOutToBeText() {
    // "<t" could be the start of <think>; when the next chunk disproves it, the held
    // characters must be released, not swallowed.
    XCTAssertEqual(run(["a <t", "ip: read on."]), "a <tip: read on.")
  }

  func testTextBeforeAndAfterBlockSurvives() {
    XCTAssertEqual(
      run(["Well, <think>hmm</think> it means to guess."]),
      "Well,  it means to guess."
    )
  }

  func testUnclosedBlockDiscardsToEnd() {
    // A block that never closes must never leak — silence beats spoken reasoning.
    XCTAssertEqual(run(["<think>never closes", " more reasoning"]), "")
  }
}
