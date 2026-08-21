//
// StartReadingSessionIntent.swift
//
// "Start a reading session" as a system-visible action: Shortcuts, Spotlight, the
// Action Button, Back Tap — every path Apple gives for starting something without
// hunting through the app.
//
// `openAppWhenRun` is not a compromise, it is the constraint: a session needs the
// microphone, and iOS only grants the microphone to a foreground app. So the intent's
// whole job is to open the app pointed at a session; the router carries the pointer.
//
// Deliberately no Book parameter in v1 — the session binds to a book at the end if it
// wasn't at the start, and a parameter here would make the fast path slower to invoke.
//

import AppIntents

struct StartReadingSessionIntent: AppIntent {

  static let title: LocalizedStringResource = "Start Reading Session"
  static let description = IntentDescription(
    "Starts a voice reading session. Say “Hey Luna” while reading to ask about words."
  )

  /// The microphone requires the foreground; see the header comment.
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    #if LUMINA_WIDGET_EXTENSION
    // A Control's intent performs in the WIDGET process, where the app's launch
    // router doesn't exist — setting a flag here would set it in the wrong process.
    // Handing back an OpenURLIntent routes the request through the app's
    // .onOpenURL, the same door the widget tile uses.
    return .result(opensIntent: OpenURLIntent(URL(string: "luminareading://voice-session")!))
    #else
    // From Shortcuts, Spotlight, or the Action Button the intent performs in the
    // app itself, so the router is the direct path.
    SessionLaunchRouter.shared.requestSession()
    return .result()
    #endif
  }
}

#if !LUMINA_WIDGET_EXTENSION
/// Registers the phrase-less shortcut so the intent shows up pre-made in the
/// Shortcuts app and in Spotlight without the reader building anything.
/// App target only — a second registration from the widget process would be
/// a duplicate provider.
struct LuminaShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartReadingSessionIntent(),
      phrases: [
        "Start a reading session in \(.applicationName)",
        "Start reading with \(.applicationName)",
      ],
      shortTitle: "Reading Session",
      systemImageName: "waveform.and.mic"
    )
  }
}
#endif
