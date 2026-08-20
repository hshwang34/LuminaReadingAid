//
// ClauseSplitterTests.swift
//
// The splitter decides when a fragment is worth speaking. Break too eagerly and Luna
// stutters through half-phrases; break too late and the streaming latency win is
// spent waiting. These tests pin the boundary in both directions.
//

import XCTest
@testable import CameraAccess

final class ClauseSplitterTests: XCTestCase {

  private func split(_ text: String, splitter: inout ClauseSplitter) -> [String] {
    var clauses = splitter.consume(text)
    if let tail = splitter.flush() { clauses.append(tail) }
    return clauses
  }

  // MARK: - Sentence breaks

  func testBreaksOnSentenceTerminators() {
    var splitter = ClauseSplitter()
    let clauses = split("Lasting a very short time. Fame can be ephemeral.", splitter: &splitter)
    XCTAssertEqual(clauses, ["Lasting a very short time.", "Fame can be ephemeral."])
  }

  func testBreaksOnQuestionAndExclamation() {
    var splitter = ClauseSplitter()
    let clauses = split("Do you mean this? Yes!", splitter: &splitter)
    XCTAssertEqual(clauses, ["Do you mean this?", "Yes!"])
  }

  // MARK: - Soft breaks

  func testBreaksOnCommaOnceEnoughWordsHaveAccumulated() {
    var splitter = ClauseSplitter(minimumWordsForSoftBreak: 4)
    let clauses = split("It means very brief, fleeting and quickly gone", splitter: &splitter)
    XCTAssertEqual(clauses, ["It means very brief,", "fleeting and quickly gone"])
  }

  func testDoesNotBreakOnACommaThatArrivesTooEarly() {
    // Three words is a fragment, not a phrase — speaking it alone sounds like a stall.
    var splitter = ClauseSplitter(minimumWordsForSoftBreak: 4)
    let clauses = split("It means brief, fleeting and quickly gone", splitter: &splitter)
    XCTAssertEqual(clauses, ["It means brief, fleeting and quickly gone"])
  }

  func testDoesNotBreakOnAnEarlyComma() {
    // "Yes, it means…" must not become two utterances.
    var splitter = ClauseSplitter(minimumWordsForSoftBreak: 4)
    let clauses = split("Yes, it means brief", splitter: &splitter)
    XCTAssertEqual(clauses, ["Yes, it means brief"])
  }

  // MARK: - Runaway text

  func testBreaksOnWordCeilingWhenPunctuationNeverArrives() {
    var splitter = ClauseSplitter(minimumWordsForSoftBreak: 4, maximumWordsPerClause: 6)
    let clauses = split("one two three four five six seven eight", splitter: &splitter)
    XCTAssertEqual(clauses.count, 2)
    XCTAssertEqual(clauses.first, "one two three four five six")
  }

  // MARK: - Abbreviations and decimals

  func testDoesNotBreakInsideAnAbbreviation() {
    var splitter = ClauseSplitter()
    let clauses = split("It is used e.g. in formal writing.", splitter: &splitter)
    XCTAssertEqual(clauses, ["It is used e.g. in formal writing."])
  }

  func testDoesNotBreakInsideADecimal() {
    var splitter = ClauseSplitter()
    let clauses = split("About 3.14 in total.", splitter: &splitter)
    XCTAssertEqual(clauses, ["About 3.14 in total."])
  }

  // MARK: - Streaming behaviour

  func testEmitsFirstClauseBeforeRemainderArrives() {
    // The latency guarantee, in splitter terms.
    var splitter = ClauseSplitter()
    let first = splitter.consume("Lasting a very short time. Fame ")
    XCTAssertEqual(first, ["Lasting a very short time."])
  }

  func testHandlesCharacterByCharacterDelivery() {
    var splitter = ClauseSplitter()
    var clauses: [String] = []
    for character in "Brief and fleeting. Try it." {
      clauses.append(contentsOf: splitter.consume(String(character)))
    }
    if let tail = splitter.flush() { clauses.append(tail) }
    XCTAssertEqual(clauses, ["Brief and fleeting.", "Try it."])
  }

  // MARK: - Empty and noise

  func testIgnoresWhitespaceOnlyInput() {
    var splitter = ClauseSplitter()
    XCTAssertTrue(split("   \n  ", splitter: &splitter).isEmpty)
  }

  func testIgnoresPunctuationOnlyFragments() {
    var splitter = ClauseSplitter()
    let clauses = split("...", splitter: &splitter)
    XCTAssertTrue(clauses.isEmpty)
  }

  func testFlushReturnsNilWhenBufferIsEmpty() {
    var splitter = ClauseSplitter()
    _ = splitter.consume("Done.")
    XCTAssertNil(splitter.flush())
  }
}
