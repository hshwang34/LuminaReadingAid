//
// SessionLaunchRouter.swift
//
// The one place a "start a session" request lands, no matter where it came from.
//
// Requests arrive from outside the view tree — the App Intent fires from Shortcuts
// or the Action Button before any view exists, and a URL open arrives on the scene.
// Views can't be handed these directly, so the router holds the request and the root
// view observes it: whoever is on screen presents the session and clears the flag.
//
// Deliberately not a queue. Two "start" requests before the view reacts mean the
// reader mashed the button — one session is the right response.
//

import Foundation
import Observation

@MainActor
@Observable
final class SessionLaunchRouter {

  static let shared = SessionLaunchRouter()

  /// Set when something outside the view tree asked for a live session.
  /// The root view observes this, presents the session, and calls `consume()`.
  private(set) var pendingLaunch = false
  /// A launch may name the book to read (Book Detail's CTA); external entry
  /// points (widget, Control, URL) leave it nil and the reader binds by voice.
  private(set) var pendingBook: Book?

  func requestSession(book: Book? = nil) {
    pendingBook = book
    pendingLaunch = true
  }

  func consume() {
    pendingLaunch = false
    pendingBook = nil
  }

  /// The URL scheme half of the entry points. `luminareading://voice-session`
  /// starts a session; anything else is ignored rather than guessed at.
  /// (The legacy `cameraaccess://` scheme belongs to the Meta SDK and is never
  /// extended — it dies with the glasses code.)
  func handle(_ url: URL) {
    guard url.scheme == "luminareading" else { return }
    if url.host == "voice-session" || url.path.contains("voice-session") {
      requestSession()
    }
  }
}
