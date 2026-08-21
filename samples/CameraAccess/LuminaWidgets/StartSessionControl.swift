//
// StartSessionControl.swift
//
// The iOS 18 Control: one button in Control Center or on the Lock Screen that
// starts a reading session. This is the "pick up the book, tap once, start
// reading" path — the fastest entry the platform allows.
//

import AppIntents
import SwiftUI
import WidgetKit

struct StartSessionControl: ControlWidget {

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "com.Lumina.ReadingAid.startSession") {
      ControlWidgetButton(action: StartReadingSessionIntent()) {
        Label("Reading Session", systemImage: "waveform.and.mic")
      }
    }
    .displayName("Reading Session")
    .description("Start a voice reading session.")
  }
}
