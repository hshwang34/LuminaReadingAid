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

/// Pen & Paper, reduced to what the lock screen needs.
enum Palette {
  static let parchment = Color(red: 247/255, green: 243/255, blue: 237/255)
  static let ink = Color(red: 61/255, green: 46/255, blue: 31/255)
  static let leather = Color(red: 122/255, green: 92/255, blue: 62/255)
  static let amber = Color(red: 196/255, green: 149/255, blue: 106/255)
  static let brick = Color(red: 184/255, green: 92/255, blue: 74/255)
}
