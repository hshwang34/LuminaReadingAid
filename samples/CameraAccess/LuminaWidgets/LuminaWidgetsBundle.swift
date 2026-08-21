//
// LuminaWidgetsBundle.swift
//
// The widget extension's entry point: the session's lock-screen face, the Control
// Center / Lock Screen button that starts one, and a Home Screen tile.
//

import SwiftUI
import WidgetKit

@main
struct LuminaWidgetsBundle: WidgetBundle {
  var body: some Widget {
    VoiceSessionLiveActivity()
    StartSessionControl()
    StartSessionWidget()
  }
}
