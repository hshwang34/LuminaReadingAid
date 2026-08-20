//
// StreamingJSONFieldScannerTests.swift
//
// The scanner is what lets speech start before generation finishes, so its contract
// is timing-sensitive: `short_gloss` must be emitted the instant its closing quote
// arrives, not when the object closes. These tests drive it one character at a time
// to prove that, and to prove it doesn't emit early or twice.
//
// Also covers the defensive paths — a stray <think> block, prose around the JSON,
// truncated output — because each of those, unhandled, becomes something spoken
// aloud to the reader.
//

import XCTest
@testable import CameraAccess

final class StreamingJSONFieldScannerTests: XCTestCase {

  private var groundedScanner: StreamingJSONFieldScanner {
    StreamingJSONFieldScanner(expected: AnswerSchema.groundedKeys)
  }

  private let sample = #"{"sense_id": 1, "short_gloss": "lasting a very short time", "example": "Fame can be ephemeral.", "confidence": "high"}"#

  /// Feeds a string one character at a time, collecting every emission.
  private func streamCharByCharacter(
    _ text: String,
    into scanner: inout StreamingJSONFieldScanner
  ) -> [StreamingJSONFieldScanner.Emitted] {
    var emitted: [StreamingJSONFieldScanner.Emitted] = []
    for character in text {
      emitted.append(contentsOf: scanner.consume(String(character)))
    }
    return emitted
  }

  // MARK: - Incremental emission

  func testEmitsFieldsInOrderWhenStreamedCharacterByCharacter() {
    var scanner = groundedScanner
    let emitted = streamCharByCharacter(sample, into: &scanner)

    XCTAssertEqual(emitted.map(\.key), ["sense_id", "short_gloss", "example", "confidence"])
    XCTAssertEqual(emitted[0].value, "1")
    XCTAssertEqual(emitted[1].value, "lasting a very short time")
    XCTAssertEqual(emitted[2].value, "Fame can be ephemeral.")
    XCTAssertEqual(emitted[3].value, "high")
    XCTAssertTrue(scanner.isComplete)
  }

  func testGlossIsEmittedBeforeExampleHasArrived() {
    // This is the latency guarantee: speech can begin at this point.
    var scanner = groundedScanner
    let partial = #"{"sense_id": 1, "short_gloss": "lasting a very short time", "exam"#
    let emitted = streamCharByCharacter(partial, into: &scanner)

    XCTAssertEqual(emitted.map(\.key), ["sense_id", "short_gloss"])
    XCTAssertFalse(scanner.isComplete)
  }

  func testDoesNotEmitAStringValueBeforeItsClosingQuote() {
    var scanner = groundedScanner
    let partial = #"{"sense_id": 1, "short_gloss": "lasting a very"#
    let emitted = streamCharByCharacter(partial, into: &scanner)

    XCTAssertEqual(emitted.map(\.key), ["sense_id"])
  }

  func testDoesNotEmitABareValueBeforeItsTerminator() {
    var scanner = groundedScanner
    // "1" could still become "12" — wait for the delimiter.
    let emitted = streamCharByCharacter(#"{"sense_id": 1"#, into: &scanner)
    XCTAssertTrue(emitted.isEmpty)
  }

  func testEachFieldIsEmittedExactlyOnce() {
    var scanner = groundedScanner
    var all = streamCharByCharacter(sample, into: &scanner)
    all.append(contentsOf: scanner.consume(""))
    all.append(contentsOf: scanner.consume(" "))

    XCTAssertEqual(all.filter { $0.key == "short_gloss" }.count, 1)
  }

  func testHandlesChunkedDelivery() {
    var scanner = groundedScanner
    var emitted: [StreamingJSONFieldScanner.Emitted] = []
    for chunk in [#"{"sense_id""#, #": 2, "short_gl"#, #"oss": "a te"#, #"st", "example": "x y."#,
                  #"", "confidence": "medi"#, #"um"}"#] {
      emitted.append(contentsOf: scanner.consume(chunk))
    }
    XCTAssertEqual(emitted.map(\.key), ["sense_id", "short_gloss", "example", "confidence"])
    XCTAssertEqual(emitted[1].value, "a test")
    XCTAssertEqual(emitted[3].value, "medium")
  }

  // MARK: - Escapes

  func testUnescapesStringContent() {
    var scanner = groundedScanner
    let text = #"{"sense_id": 1, "short_gloss": "he said \"stop\" loudly", "example": "line\nbreak", "confidence": "low"}"#
    let emitted = streamCharByCharacter(text, into: &scanner)

    XCTAssertEqual(emitted[1].value, "he said \"stop\" loudly")
    XCTAssertEqual(emitted[2].value, "line\nbreak")
  }

  func testEscapedQuoteDoesNotTerminateValueEarly() {
    var scanner = groundedScanner
    let partial = #"{"sense_id": 1, "short_gloss": "a \"quoted"#
    let emitted = streamCharByCharacter(partial, into: &scanner)
    XCTAssertEqual(emitted.map(\.key), ["sense_id"])
  }

  // MARK: - Defensive paths

  func testSkipsThinkBlockIfTheModelEmitsOne() {
    // The no-thinking switch is belt-and-braces; if both fail, reasoning must never
    // reach the speaker.
    var scanner = groundedScanner
    let text = "<think>The reader wants sense 1 because {not json}</think>" + sample
    let emitted = streamCharByCharacter(text, into: &scanner)

    XCTAssertEqual(emitted.map(\.key), ["sense_id", "short_gloss", "example", "confidence"])
    XCTAssertEqual(emitted[1].value, "lasting a very short time")
  }

  func testSkipsLeadingProse() {
    var scanner = groundedScanner
    let emitted = streamCharByCharacter("Here is the answer:\n" + sample, into: &scanner)
    XCTAssertEqual(emitted.count, 4)
  }

  func testTruncatedOutputEmitsWhatCompletedAndNoMore() {
    var scanner = groundedScanner
    let truncated = #"{"sense_id": 3, "short_gloss": "cut off here"#
    let emitted = streamCharByCharacter(truncated, into: &scanner)

    XCTAssertEqual(emitted.map(\.key), ["sense_id"])
    XCTAssertFalse(scanner.isComplete)
  }

  func testNoJSONAtAllEmitsNothing() {
    var scanner = groundedScanner
    let emitted = streamCharByCharacter("I'm sorry, I don't know that word.", into: &scanner)
    XCTAssertTrue(emitted.isEmpty)
    XCTAssertNil(scanner.jsonObjectText)
  }

  // MARK: - Decoding

  func testDecodesCompletedObject() throws {
    var scanner = groundedScanner
    _ = scanner.consume(sample)

    let answer = try scanner.decode(GroundedAnswer.self)
    XCTAssertEqual(answer.senseID, 1)
    XCTAssertEqual(answer.shortGloss, "lasting a very short time")
    XCTAssertEqual(answer.confidence, .high)
  }

  func testDecodeThrowsOnTruncatedObject() {
    var scanner = groundedScanner
    _ = scanner.consume(#"{"sense_id": 1, "short_gloss": "unfinished"#)
    XCTAssertThrowsError(try scanner.decode(GroundedAnswer.self))
  }

  func testDecodeIgnoresTrailingProse() throws {
    var scanner = groundedScanner
    _ = scanner.consume(sample + "\nHope that helps!")
    let answer = try scanner.decode(GroundedAnswer.self)
    XCTAssertEqual(answer.senseID, 1)
  }

  // MARK: - Follow-up shape

  func testFollowUpKeysScanIndependently() throws {
    var scanner = StreamingJSONFieldScanner(expected: AnswerSchema.followUpKeys)
    let text = #"{"answer": "Because it comes from Latin.", "confidence": "medium"}"#
    let emitted = streamCharByCharacter(text, into: &scanner)

    XCTAssertEqual(emitted.map(\.key), ["answer", "confidence"])
    let decoded = try scanner.decode(FollowUpAnswer.self)
    XCTAssertEqual(decoded.answer, "Because it comes from Latin.")
  }

  // MARK: - Validation

  func testValidationClampsOutOfRangeSenseID() {
    let answer = GroundedAnswer(senseID: 9, shortGloss: "x", example: "y", confidence: .high)
    let validated = answer.validated(againstSenseCount: 3)
    XCTAssertEqual(validated.senseID, 0)
    XCTAssertEqual(validated.confidence, .low)
  }

  func testValidationDowngradesNoSenseFits() {
    let answer = GroundedAnswer(senseID: 0, shortGloss: "x", example: "y", confidence: .high)
    XCTAssertEqual(answer.validated(againstSenseCount: 3).confidence, .low)
  }

  func testValidationKeepsGoodAnswerIntact() {
    let answer = GroundedAnswer(senseID: 2, shortGloss: "  a meaning ", example: " an example ", confidence: .high)
    let validated = answer.validated(againstSenseCount: 3)
    XCTAssertEqual(validated.senseID, 2)
    XCTAssertEqual(validated.shortGloss, "a meaning")
    XCTAssertEqual(validated.example, "an example")
    XCTAssertEqual(validated.confidence, .high)
  }

  func testValidationDowngradesEmptyGloss() {
    let answer = GroundedAnswer(senseID: 1, shortGloss: "   ", example: "y", confidence: .high)
    XCTAssertEqual(answer.validated(againstSenseCount: 3).confidence, .low)
  }
}
