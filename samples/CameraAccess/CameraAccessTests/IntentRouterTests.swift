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

  // No LLM fallback injected: with model-first routing these tests exercise the
  // emergency table — the path that answers when the model can't. The classifier's
  // own behaviour is prompt+grammar, verified on device.
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

  // MARK: - Define, inverted and embedded forms
  //
  // Every phrasing here was spoken to a real device and routed to `unintelligible`
  // before these patterns existed — the transcription was perfect and the routing
  // table simply didn't know the shape.

  func testExplainAndEmbeddedMeansForms() async {
    var intent = await route("Can you explain what divine means?")
    XCTAssertEqual(intent, .define(word: "divine", contextSentence: nil))

    intent = await route("do you know what precision means")
    XCTAssertEqual(intent, .define(word: "precision", contextSentence: nil))

    intent = await route("tell me what ephemeral means")
    XCTAssertEqual(intent, .define(word: "ephemeral", contextSentence: nil))

    intent = await route("explain perfunctory")
    XCTAssertEqual(intent, .define(word: "perfunctory", contextSentence: nil))

    intent = await route("could you explain the word divine?")
    XCTAssertEqual(intent, .define(word: "divine", contextSentence: nil))
  }

  func testExplainWhatMeansDoesNotCaptureTheWordMeans() async {
    // "explain what X means" must hit the embedded rule first; the bare `explain`
    // rule would swallow the clause and extract "means" as the word.
    let intent = await route("explain what divine means")
    XCTAssertEqual(intent, .define(word: "divine", contextSentence: nil))
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

  // MARK: - Speculative prefetch
  //
  // These run against *incomplete* sentences, because that is the only time the
  // result is useful: the dictionary lookup has to start while the reader is still
  // speaking for it to be free by the time they stop.

  func testLikelyTargetWordFiresBeforeTheSentenceIsFinished() {
    // The point of these is the word arriving early. Each string here is what the
    // recogniser has produced partway through the reader's question, not after it.
    XCTAssertEqual(IntentRouter.likelyTargetWord(in: "what does precision"), "precision")
    XCTAssertEqual(IntentRouter.likelyTargetWord(in: "how do you pronounce ephemeral"), "ephemeral")
    XCTAssertEqual(IntentRouter.likelyTargetWord(in: "use divine"), "divine")
    XCTAssertEqual(IntentRouter.likelyTargetWord(in: "what's the definition of perfunctory"), "perfunctory")
    XCTAssertEqual(IntentRouter.likelyTargetWord(in: "define ephemeral"), "ephemeral")
  }

  func testLikelyTargetWordStillWorksOnCompletedSentences() {
    XCTAssertEqual(IntentRouter.likelyTargetWord(in: "what does precision mean?"), "precision")
    XCTAssertEqual(
      IntentRouter.likelyTargetWord(in: "what does divine mean in she divines her way"),
      "divine"
    )
  }

  func testLikelyTargetWordReturnsNilRatherThanGuessing() {
    // A wrong guess only costs a cache entry nobody reads, but prefetching on
    // anaphora would fire a lookup for the literal word "it" on every follow-up.
    XCTAssertNil(IntentRouter.likelyTargetWord(in: "what does it mean"))
    XCTAssertNil(IntentRouter.likelyTargetWord(in: "use it in a sentence"))
    XCTAssertNil(IntentRouter.likelyTargetWord(in: "what"))
    XCTAssertNil(IntentRouter.likelyTargetWord(in: "say that again"))
    XCTAssertNil(IntentRouter.likelyTargetWord(in: ""))
  }
}

// MARK: - Helpers

/// Actor-isolated counter so the Sendable fallback closure can record calls.
private actor Counter {
  private(set) var value = 0
  func increment() { value += 1 }
}
