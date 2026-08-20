//
// IntentRouterTests.swift
//
// Covers the deterministic routing table. Every pattern in IntentRouter is compiled
// with try! at first use, so exercising all of them here is also what makes that
// force-unwrap safe: a malformed pattern fails the test suite rather than a session.
//
// The LLM fallback is deliberately not injected in most tests — these assert what the
// router can do without ever waking the model, which is the fast path that has to
// carry the overwhelming majority of real utterances.
//

import XCTest
@testable import CameraAccess

final class IntentRouterTests: XCTestCase {

  private let router = IntentRouter()

  private func route(_ utterance: String, context: SessionContext = .empty) async -> SessionIntent {
    await router.route(utterance, context: context)
  }

  private var afterAnswer: SessionContext {
    SessionContext(lastAnswerWord: "precision", lastAnswerSenseID: 1)
  }

  // MARK: - Define

  func testDefineBasicForms() async {
    let expected = SessionIntent.define(word: "precision", contextSentence: nil)
    for utterance in [
      "what does precision mean",
      "what does precision mean?",
      "define precision",
      "what is the meaning of precision",
      "what's the definition of precision",
      "meaning of precision",
      "precision means what",
    ] {
      let intent = await route(utterance)
      XCTAssertEqual(intent, expected, "failed for: \(utterance)")
    }
  }

  func testDefineStripsFillerAroundTheWord() async {
    // "the word precision" must not reduce to "the".
    let intent = await route("what does the word precision mean")
    XCTAssertEqual(intent, .define(word: "precision", contextSentence: nil))
  }

  func testDefineCapturesReaderSentence() async {
    let intent = await route("what does divine mean in she divines her way")
    XCTAssertEqual(intent, .define(word: "divine", contextSentence: "she divines her way"))
  }

  func testDefineCapturesSentenceAfterExplicitMarker() async {
    let intent = await route("what does divine mean in this sentence she divines her way")
    XCTAssertEqual(intent, .define(word: "divine", contextSentence: "she divines her way"))
  }

  func testDefineIgnoresSentenceSlotTooShortToBeOne() async {
    // "in context" is not a sentence; it shouldn't be stored as one.
    let intent = await route("what does divine mean in context")
    XCTAssertEqual(intent, .define(word: "divine", contextSentence: nil))
  }

  func testDefineResolvesAnaphoraToLastWord() async {
    let intent = await route("what does it mean", context: afterAnswer)
    XCTAssertEqual(intent, .define(word: "precision", contextSentence: nil))
  }

  // MARK: - Example sentence

  func testExampleSentenceForms() async {
    let expected = SessionIntent.exampleSentence(word: "precision")
    for utterance in [
      "use precision in a sentence",
      "use the word precision in a sentence",
      "give me an example with precision",
      "show me an example using precision",
    ] {
      let intent = await route(utterance)
      XCTAssertEqual(intent, expected, "failed for: \(utterance)")
    }
  }

  func testBareExampleRequestUsesLastAnsweredWord() async {
    let expected = SessionIntent.exampleSentence(word: "precision")
    for utterance in ["example", "another example", "use it in a sentence"] {
      let intent = await route(utterance, context: afterAnswer)
      XCTAssertEqual(intent, expected, "failed for: \(utterance)")
    }
  }

  func testBareExampleRequestWithoutContextIsUnintelligible() async {
    let intent = await route("example")
    XCTAssertEqual(intent, .unintelligible)
  }

  // MARK: - Pronounce

  func testPronounceForms() async {
    let expected = SessionIntent.pronounce(word: "precision")
    for utterance in [
      "how do you say precision",
      "how do i pronounce precision",
      "pronounce precision",
      "how is precision pronounced",
    ] {
      let intent = await route(utterance)
      XCTAssertEqual(intent, expected, "failed for: \(utterance)")
    }
  }

  // MARK: - Repeat

  func testRepeatForms() async {
    for utterance in ["say that again", "say it again", "repeat that", "repeat", "again", "one more time"] {
      let intent = await route(utterance, context: afterAnswer)
      XCTAssertEqual(intent, .repeatLast, "failed for: \(utterance)")
    }
  }

  // MARK: - End session

  func testEndSessionForms() async {
    for utterance in [
      "stop", "done", "finish", "quit",
      "that's all", "that's it", "goodbye", "good night",
      "end the session", "stop listening",
    ] {
      let intent = await route(utterance)
      XCTAssertEqual(intent, .endSession, "failed for: \(utterance)")
    }
  }

  func testEndSessionDoesNotSwallowLegitimateQuestions() async {
    // "stop" appears inside the question but isn't the request.
    let intent = await route("what does stoppage mean")
    XCTAssertEqual(intent, .define(word: "stoppage", contextSentence: nil))
  }

  // MARK: - Follow-up

  func testFollowUpAfterAnAnswer() async {
    let intent = await route("why is it spelled that way", context: afterAnswer)
    XCTAssertEqual(intent, .followUp(question: "why is it spelled that way"))
  }

  func testFollowUpRequiresPriorAnswer() async {
    // With no previous answer there's nothing for a follow-up to refer to.
    let intent = await route("why is it spelled that way")
    XCTAssertEqual(intent, .unintelligible)
  }

  // MARK: - Unintelligible

  func testEmptyAndNoiseAreUnintelligible() async {
    for utterance in ["", "   ", "mm"] {
      let intent = await route(utterance)
      XCTAssertEqual(intent, .unintelligible, "failed for: \(utterance.debugDescription)")
    }
  }

  // MARK: - LLM fallback

  func testFallbackIsConsultedOnlyWhenPatternsMiss() async {
    let called = Counter()
    let fallbackRouter = IntentRouter { _, _ in
      await called.increment()
      return .define(word: "perfunctory", contextSentence: nil)
    }

    // A clean pattern match must not wake the model.
    _ = await fallbackRouter.route("what does precision mean", context: .empty)
    let afterHit = await called.value
    XCTAssertEqual(afterHit, 0)

    // An odd phrasing should.
    let intent = await fallbackRouter.route("could you tell me about perfunctory", context: .empty)
    let afterMiss = await called.value
    XCTAssertEqual(afterMiss, 1)
    XCTAssertEqual(intent, .define(word: "perfunctory", contextSentence: nil))
  }

  func testFallbackIsSkippedForSingleWordUtterances() async {
    let called = Counter()
    let fallbackRouter = IntentRouter { _, _ in
      await called.increment()
      return .define(word: "x", contextSentence: nil)
    }
    let intent = await fallbackRouter.route("mumble", context: .empty)
    let count = await called.value
    XCTAssertEqual(count, 0)
    XCTAssertEqual(intent, .unintelligible)
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
}

// MARK: - Helpers

/// Actor-isolated counter so the Sendable fallback closure can record calls.
private actor Counter {
  private(set) var value = 0
  func increment() { value += 1 }
}
