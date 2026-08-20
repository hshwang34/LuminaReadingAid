//
// SFSpeechWakeWordSpotter.swift
//
// Spots "Hey Luna" in the transcript the session is already producing.
//
// iOS does not let a third-party app register a wake phrase, so there is no
// always-on, near-zero-power path like Siri's. What there is: a recogniser that is
// already open because the reader is speaking, and a transcript that is already being
// produced. Reading the wake phrase out of that costs one string scan per partial.
//
// This is why the app's "always on" is scoped to a session the reader deliberately
// starts, rather than to the phone. Within a session the phrase works exactly as
// expected; outside one, nothing is listening, and the app says so plainly.
//
// Matching itself lives in WakePhraseMatcher — a pure struct with unit tests, because
// wake quality is the thing most likely to need tuning against real users, and tuning
// is only cheap when it can be done without a device.
//

import Foundation
import os

@MainActor
final class SFSpeechWakeWordSpotter: WakeWordSpotting {

  private let transcriber: UtteranceTranscriber
  private var matcher: WakePhraseMatcher

  private var observer: UUID?
  private var continuation: AsyncStream<WakeEvent>.Continuation?

  /// One wake per burst. Without this the phrase re-matches on every partial for as
  /// long as the reader keeps talking, and the session would restart its capture
  /// mid-question.
  private var hasWokenThisBurst = false

  init(transcriber: UtteranceTranscriber, matcher: WakePhraseMatcher = WakePhraseMatcher()) {
    self.transcriber = transcriber
    self.matcher = matcher
  }

  // MARK: - WakeWordSpotting

  func startSpotting() -> AsyncStream<WakeEvent> {
    stopSpotting()

    let (stream, continuation) = AsyncStream<WakeEvent>.makeStream()
    self.continuation = continuation

    observer = transcriber.observers.add { [weak self] event in
      self?.handle(event)
    }

    continuation.onTermination = { [weak self] _ in
      Task { @MainActor in self?.stopSpotting() }
    }

    return stream
  }

  func stopSpotting() {
    if let observer { transcriber.observers.remove(observer) }
    observer = nil
    continuation?.finish()
    continuation = nil
    hasWokenThisBurst = false
  }

  func trailingUtterance(in transcript: String) -> String? {
    matcher.match(in: transcript)?.trailing
  }

  // MARK: - Detection

  private func handle(_ event: UtteranceTranscriber.Event) {
    switch event {
    case .partial(let text):
      guard !hasWokenThisBurst, let match = matcher.match(in: text) else { return }
      hasWokenThisBurst = true
      Log.wake.info("wake matched \"\(match.matchedPhrase, privacy: .public)\" — trailing: \"\(match.trailing, privacy: .public)\"")
      continuation?.yield(WakeEvent(trailingTranscript: match.trailing))

    case .burstEnded:
      hasWokenThisBurst = false

    case .unavailable:
      break
    }
  }
}
