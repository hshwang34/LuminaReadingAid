//
// VoiceSessionLiveActivity.swift
//
// The session on the lock screen — which, for an app built around reading with the
// phone face-down, is where the session actually lives.
//
// Pen & Paper palette, hand-inlined: the widget target doesn't compile the app's
// DesignSystem, and seven colour values aren't worth a shared dependency.
//

import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

struct VoiceSessionLiveActivity: Widget {

  var body: some WidgetConfiguration {
    ActivityConfiguration(for: VoiceSessionActivityAttributes.self) { context in
      LockScreenView(context: context)
        .activityBackgroundTint(Palette.parchment)
        .activitySystemActionForegroundColor(Palette.ink)

    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label(context.state.phaseLabel, systemImage: iconName(for: context.state))
            .font(.caption)
            .foregroundStyle(Palette.leather)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(wordText(context.state.wordCount))
            .font(.caption)
            .foregroundStyle(Palette.leather)
        }
        DynamicIslandExpandedRegion(.bottom) {
          HStack {
            Text(context.attributes.bookTitle ?? "Reading session")
              .font(.footnote.weight(.semibold))
              .lineLimit(1)
            Spacer()
            Button(intent: EndReadingSessionIntent()) {
              Text("End").font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(Palette.amber)
          }
        }
      } compactLeading: {
        Image(systemName: iconName(for: context.state))
          .foregroundStyle(Palette.amber)
      } compactTrailing: {
        Text("\(context.state.wordCount)")
          .foregroundStyle(Palette.amber)
          .monospacedDigit()
      } minimal: {
        Image(systemName: iconName(for: context.state))
          .foregroundStyle(Palette.amber)
      }
    }
  }

  private func iconName(for state: VoiceSessionActivityAttributes.ContentState) -> String {
    state.isPaused ? "mic.slash" : "waveform.and.mic"
  }

  private func wordText(_ count: Int) -> String {
    count == 1 ? "1 word" : "\(count) words"
  }
}

// MARK: - Lock screen banner

private struct LockScreenView: View {
  let context: ActivityViewContext<VoiceSessionActivityAttributes>

  var body: some View {
    HStack(spacing: 12) {
      Circle()
        .fill(context.state.isPaused ? Palette.brick : Palette.amber)
        .frame(width: 10, height: 10)

      VStack(alignment: .leading, spacing: 2) {
        Text(context.attributes.bookTitle ?? "Reading session")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Palette.ink)
          .lineLimit(1)
        Text(statusLine)
          .font(.caption)
          .foregroundStyle(Palette.leather)
      }

      Spacer()

      Button(intent: EndReadingSessionIntent()) {
        Text("End")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Palette.ink)
      }
      .buttonStyle(.bordered)
      .tint(Palette.amber)
    }
    .padding(14)
  }

  private var statusLine: String {
    if context.state.isPaused { return "Paused — open to resume" }
    let words = context.state.wordCount
    let count = words == 1 ? "1 word" : "\(words) words"
    return "\(context.state.phaseLabel) · \(count) · say “Hey Luna”"
  }
}

// MARK: - Palette

/// Notebook Minimal, reduced to what the lock screen needs. Mirrors the app's
/// DesignSystem values (the widget target doesn't compile DesignSystem.swift);
/// dynamic so widgets and the Live Activity are legible in both appearances.
enum Palette {
  private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
    func component(_ hex: UInt32, _ shift: UInt32) -> CGFloat {
      CGFloat((hex >> shift) & 0xFF) / 255
    }
    return Color(uiColor: UIColor { trait in
      let hex = trait.userInterfaceStyle == .dark ? dark : light
      return UIColor(
        red: component(hex, 16), green: component(hex, 8), blue: component(hex, 0), alpha: 1)
    })
  }

  static let parchment = dynamic(0xFAF9F7, 0x141312)
  static let linen = dynamic(0xF1EFEC, 0x211F1D)
  static let ink = dynamic(0x1C1B1A, 0xF2F1EF)
  static let leather = dynamic(0x6B6560, 0xA8A19A)
  static let amber = dynamic(0xCC8A3D, 0xE0A155)
  static let brick = dynamic(0xD65F4C, 0xE8836F)
}
