//
// VoiceSessionActivityAttributes.swift
//
// The data contract between the running session and its Live Activity.
//
// Compiled into BOTH the app and the widget extension — the two processes must agree
// on this layout byte-for-byte, which is why it lives in Shared/ and imports nothing
// but ActivityKit.
//
// The Live Activity is doing two jobs at once: it is the session's face while the
// phone is locked (word count, listening state, an End button that works without
// unlocking), and it is the visible evidence App Review guideline 2.5.4 asks for —
// an app that holds the microphone in the background must show the user that it is.
//

import ActivityKit
import Foundation

struct VoiceSessionActivityAttributes: ActivityAttributes {

  /// What changes while the session runs.
  struct ContentState: Codable, Hashable {
    /// One-word description of what Luna is doing: "Listening", "Thinking",
    /// "Speaking", "Paused". Kept as a string so the widget needs no session enum.
    var phaseLabel: String
    /// Words asked about so far.
    var wordCount: Int
    var isPaused: Bool
  }

  /// Fixed for the life of the activity.
  var bookTitle: String?
  var startedAt: Date
}
