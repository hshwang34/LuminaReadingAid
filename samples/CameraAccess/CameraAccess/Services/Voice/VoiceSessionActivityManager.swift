//
// VoiceSessionActivityManager.swift
//
// Starts, updates, and ends the session's Live Activity. App target only — the
// widget renders the activity; this side feeds it.
//
// Updates are deliberately coarse. A Live Activity update wakes the widget process
// and re-renders the lock screen; pushing every phase flicker through that would
// burn battery drawing states nobody sees. The activity hears about the phases a
// reader can act on — listening, paused — plus the word count, and nothing else.
//

import ActivityKit
import Foundation
import os

@MainActor
final class VoiceSessionActivityManager {

  private var activity: Activity<VoiceSessionActivityAttributes>?
  private var lastState: VoiceSessionActivityAttributes.ContentState?

  func start(bookTitle: String?, startedAt: Date) {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      Log.session.info("live activities disabled — session runs without one")
      return
    }
    guard activity == nil else { return }

    let attributes = VoiceSessionActivityAttributes(bookTitle: bookTitle, startedAt: startedAt)
    let state = VoiceSessionActivityAttributes.ContentState(
      phaseLabel: "Listening", wordCount: 0, isPaused: false
    )

    do {
      activity = try Activity.request(
        attributes: attributes,
        content: .init(state: state, staleDate: nil)
      )
      lastState = state
      Log.session.info("live activity started")
    } catch {
      // Not fatal: the session works without a lock-screen face.
      Log.session.error("live activity failed to start: \(error.localizedDescription, privacy: .public)")
    }
  }

  func update(phaseLabel: String, wordCount: Int, isPaused: Bool) {
    guard let activity else { return }
    let state = VoiceSessionActivityAttributes.ContentState(
      phaseLabel: phaseLabel, wordCount: wordCount, isPaused: isPaused
    )
    guard state != lastState else { return }
    lastState = state
    Task { await activity.update(.init(state: state, staleDate: nil)) }
  }

  /// Replace the activity so the lock screen shows a newly bound book title.
  /// `bookTitle` is a fixed ActivityKit attribute — the only way to change it is
  /// to end the current activity and request a fresh one.
  func rebind(bookTitle: String?, startedAt: Date) {
    guard let current = activity else { return }
    let carried = lastState
    activity = nil
    lastState = nil
    Task { await current.end(nil, dismissalPolicy: .immediate) }
    start(bookTitle: bookTitle, startedAt: startedAt)
    if let carried {
      update(phaseLabel: carried.phaseLabel, wordCount: carried.wordCount, isPaused: carried.isPaused)
    }
  }

  /// Ends with a short-lived summary so the reader sees what the session gathered.
  func end(wordCount: Int) {
    guard let activity else { return }
    self.activity = nil
    lastState = nil
    let final = VoiceSessionActivityAttributes.ContentState(
      phaseLabel: "Session ended", wordCount: wordCount, isPaused: false
    )
    Task {
      await activity.end(
        .init(state: final, staleDate: nil),
        dismissalPolicy: .after(.now + 10)
      )
    }
  }
}
