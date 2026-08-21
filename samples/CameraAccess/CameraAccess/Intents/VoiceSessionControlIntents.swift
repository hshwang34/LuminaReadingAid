//
// VoiceSessionControlIntents.swift
//
// Session control from the Live Activity: the End button on the lock screen.
//
// `LiveActivityIntent` is the whole trick — it performs in the APP's process, not
// the widget's, without foregrounding anything. That is exactly right for ending a
// session from a locked phone: the app is already alive (it is holding the
// microphone), the intent reaches straight into it, and the reader never unlocks.
//
// Compiled into both targets so the widget can name the type; only the app's copy
// ever executes.
//

import AppIntents

struct EndReadingSessionIntent: LiveActivityIntent {

  static let title: LocalizedStringResource = "End Reading Session"
  static let description = IntentDescription("Ends the current voice reading session.")
  /// Ending a session from the lock screen must not demand Face ID first.
  static let isDiscoverable = false

  @MainActor
  func perform() async throws -> some IntentResult {
    #if !LUMINA_WIDGET_EXTENSION
    VoiceSessionController.active?.end(.manual)
    #endif
    return .result()
  }
}
