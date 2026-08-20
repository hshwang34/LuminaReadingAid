//
// Log.swift
//
// One logger per pipeline stage, so the Xcode console can tell the story of a
// voice turn end to end:
//
//   audio    — engine lifecycle, voice activity, interruptions, route changes
//   stt      — recognition bursts opening, closing, rotating
//   wake     — wake-phrase matches
//   session  — the state machine: every phase transition, every turn
//   answer   — routing, grounding, first-audio and total latency
//   llm      — model load, prefill, token throughput
//   tts      — clauses queued and the queue draining
//
// Filter the console to `subsystem:com.Lumina.ReadingAid` to see only these, or to a
// single category to watch one stage. Everything is logged `.public` on purpose: this
// is a debugging surface for a development device, and a redacted transcript is
// useless for diagnosing why a question was dropped.
//

import os

enum Log {
  private static let subsystem = "com.Lumina.ReadingAid"

  static let audio = Logger(subsystem: subsystem, category: "audio")
  static let stt = Logger(subsystem: subsystem, category: "stt")
  static let wake = Logger(subsystem: subsystem, category: "wake")
  static let session = Logger(subsystem: subsystem, category: "session")
  static let answer = Logger(subsystem: subsystem, category: "answer")
  static let llm = Logger(subsystem: subsystem, category: "llm")
  static let tts = Logger(subsystem: subsystem, category: "tts")
}
