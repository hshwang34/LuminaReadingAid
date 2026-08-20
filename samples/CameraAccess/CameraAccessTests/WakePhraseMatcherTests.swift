//
// WakePhraseMatcherTests.swift
//
// The wake phrase is the first thing every interaction depends on, and it has to
// survive a recogniser that mishears it. These tests pin down both halves of the
// trade-off: generous enough to catch plausible mis-transcriptions, strict enough
// that ordinary speech near the phone doesn't start a question.
//
// Pure Swift — no audio, no recogniser — so variants stay cheap to add.
//

import XCTest
@testable import CameraAccess

final class WakePhraseMatcherTests: XCTestCase {

  private let matcher = WakePhraseMatcher()

  // MARK: - Straightforward detection

  func testDetectsExactPhrase() {
    let match = matcher.match(in: "Hey Luna")
    XCTAssertNotNil(match)
    XCTAssertEqual(match?.trailing, "")
  }

  func testDetectsPhraseRegardlessOfCase() {
    XCTAssertNotNil(matcher.match(in: "hey luna"))
    XCTAssertNotNil(matcher.match(in: "HEY LUNA"))
    XCTAssertNotNil(matcher.match(in: "Hey LUNA"))
  }

  func testCapturesTrailingQuestionSpokenInOneBreath() {
    // The whole point of adopting the running recogniser task: a reader who doesn't
    // pause must not lose their question.
    let match = matcher.match(in: "Hey Luna what does precision mean")
    XCTAssertEqual(match?.trailing, "what does precision mean")
  }

  func testStripsPunctuationBetweenPhraseAndQuestion() {
    let match = matcher.match(in: "Hey Luna, what does divine mean?")
    XCTAssertEqual(match?.trailing, "what does divine mean?")
  }

  func testPreservesTrailingCasing() {
    // Context sentences are stored and shown to the reader, so casing survives.
    let match = matcher.match(in: "Hey Luna what does Divine mean in She Divines Her Way")
    XCTAssertEqual(match?.trailing, "what does Divine mean in She Divines Her Way")
  }

  // MARK: - Plausible mis-transcriptions

  func testAcceptsNameWithinEditDistanceOne() {
    for variant in ["hey lunar", "hey luma", "hey lena", "hey loona", "hey lunas"] {
      XCTAssertNotNil(matcher.match(in: variant), "expected \(variant) to wake")
    }
  }

  func testAcceptsAlternateTriggerWords() {
    for variant in ["hay luna", "hi luna", "hello luna", "okay luna", "a luna", "eh luna"] {
      XCTAssertNotNil(matcher.match(in: variant), "expected \(variant) to wake")
    }
  }

  func testAcceptsDiacriticForms() {
    XCTAssertNotNil(matcher.match(in: "hey lună"))
  }

  func testAcceptsMergedToken() {
    let match = matcher.match(in: "heyluna what does ephemeral mean")
    XCTAssertNotNil(match)
    XCTAssertEqual(match?.trailing, "what does ephemeral mean")
  }

  // MARK: - Rejection

  func testRejectsNameWithoutTriggerByDefault() {
    // A character called Luna in the book must not start a question.
    XCTAssertNil(matcher.match(in: "Luna walked into the room"))
  }

  func testAcceptsBareNameWhenTriggerNotRequired() {
    let permissive = WakePhraseMatcher(requiresTrigger: false)
    XCTAssertNotNil(permissive.match(in: "Luna what does precision mean"))
  }

  func testRejectsUnrelatedSpeech() {
    for phrase in [
      "the quick brown fox",
      "hey there how are you",
      "he looked at the moon",
      "she said hello to her friend",
      "",
      "   ",
    ] {
      XCTAssertNil(matcher.match(in: phrase), "expected \(phrase.debugDescription) not to wake")
    }
  }

  func testRejectsNameTooFarFromTarget() {
    // Distance 2 or more is not a mis-transcription, it's a different word.
    XCTAssertNil(matcher.match(in: "hey london"))
    XCTAssertNil(matcher.match(in: "hey lunatic"))
  }

  func testTriggerWithoutNameDoesNotWake() {
    XCTAssertNil(matcher.match(in: "hey what does precision mean"))
  }

  // MARK: - Multiple occurrences

  func testUsesMostRecentMatchInALongPartialTranscript() {
    // Partial transcripts accumulate across a rotation window; the newest question wins.
    let transcript = "Hey Luna what does precision mean Hey Luna what does divine mean"
    XCTAssertEqual(matcher.match(in: transcript)?.trailing, "what does divine mean")
  }

  // MARK: - Edit distance primitive

  func testBoundedEditDistance() {
    XCTAssertTrue(WakePhraseMatcher.editDistance(Array("luna"), Array("luna"), atMost: 1))
    XCTAssertTrue(WakePhraseMatcher.editDistance(Array("lunar"), Array("luna"), atMost: 1))
    XCTAssertTrue(WakePhraseMatcher.editDistance(Array("lna"), Array("luna"), atMost: 1))
    XCTAssertFalse(WakePhraseMatcher.editDistance(Array("moon"), Array("luna"), atMost: 1))
    XCTAssertFalse(WakePhraseMatcher.editDistance(Array(""), Array("luna"), atMost: 1))
  }
}
