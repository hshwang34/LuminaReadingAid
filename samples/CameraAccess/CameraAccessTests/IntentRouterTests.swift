//
// IntentRouterTests.swift
//
// Covers what remains of IntentRouter after the answer path went LM-native: word
// spotting for the dictionary prefetch, and the text utilities behind it. Every
// regex is compiled with try! at first use, so exercising them here is also what
// makes that force-unwrap safe.
//

import XCTest
@testable import CameraAccess

final class IntentRouterTests: XCTestCase {

  // MARK: - Prefetch word spotting
  //
  // These run against *incomplete* sentences on purpose: the head start only exists
  // mid-sentence. Each phrasing here has been spoken to a real device.

  func testLikelyTargetWordFiresBeforeTheSentenceIsFinished() {
    XCTAssertEqual(IntentRouter.likelyTargetWord(in: "what does precision"), "precision")
    XCTAssertEqual(IntentRouter.likelyTargetWord(in: "how do you pronounce ephemeral"), "ephemeral")
    XCTAssertEqual(IntentRouter.likelyTargetWord(in: "use divine"), "divine")
    XCTAssertEqual(IntentRouter.likelyTargetWord(in: "what's the definition of perfunctory"), "perfunctory")
    XCTAssertEqual(IntentRouter.likelyTargetWord(in: "define ephemeral"), "ephemeral")
    XCTAssertEqual(IntentRouter.likelyTargetWord(in: "can you explain what divine"), "divine")
  }

  func testLikelyTargetWordOnCompletedSentences() {
    XCTAssertEqual(IntentRouter.likelyTargetWord(in: "what does precision mean?"), "precision")
    XCTAssertEqual(
      IntentRouter.likelyTargetWord(in: "what does divine mean in she divines her way"),
      "divine"
    )
    XCTAssertEqual(IntentRouter.likelyTargetWord(in: "tell me what ephemeral means"), "ephemeral")
  }

  func testLikelyTargetWordReturnsNilRatherThanGuessing() {
    // A wrong guess only costs a cache entry nobody reads, but firing on anaphora
    // would look up the literal word "it" on every follow-up.
    XCTAssertNil(IntentRouter.likelyTargetWord(in: "what does it mean"))
    XCTAssertNil(IntentRouter.likelyTargetWord(in: "use it in a sentence"))
    XCTAssertNil(IntentRouter.likelyTargetWord(in: "what"))
    XCTAssertNil(IntentRouter.likelyTargetWord(in: "say that again"))
    XCTAssertNil(IntentRouter.likelyTargetWord(in: ""))
  }

  // MARK: - Word extraction

  func testExtractWordHandlesFillerAndPunctuation() {
    XCTAssertEqual(IntentRouter.extractWord(from: "precision"), "precision")
    XCTAssertEqual(IntentRouter.extractWord(from: "the word precision"), "precision")
    XCTAssertEqual(IntentRouter.extractWord(from: "  precision,  "), "precision")
    XCTAssertEqual(IntentRouter.extractWord(from: "don't"), "don't")
    XCTAssertNil(IntentRouter.extractWord(from: "the"))
    XCTAssertNil(IntentRouter.extractWord(from: "123"))
    XCTAssertNil(IntentRouter.extractWord(from: ""))
  }

  // MARK: - Cleaning

  func testCleanCollapsesWhitespaceAndPreservesCasing() {
    XCTAssertEqual(IntentRouter.clean("  What   does\nDivine mean  "), "What does Divine mean")
    XCTAssertEqual(IntentRouter.clean(""), "")
  }
}
