//
// StartSessionWidget.swift
//
// Home Screen tile. Static by design — its whole job is to be a big tappable
// doorway into a session, so it renders one timeline entry and never wakes up
// again. The deep link does the work.
//

import SwiftUI
import WidgetKit

struct StartSessionWidget: Widget {

  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: "com.Lumina.ReadingAid.startSessionWidget",
      provider: StaticProvider()
    ) { _ in
      WidgetView()
        .containerBackground(Palette.parchment, for: .widget)
        .widgetURL(URL(string: "luminareading://voice-session"))
    }
    .configurationDisplayName("Reading Session")
    .description("Start a voice reading session with one tap.")
    .supportedFamilies([.systemSmall])
  }
}

private struct WidgetView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Image(systemName: "waveform.and.mic")
        .font(.title2)
        .foregroundStyle(Palette.amber)
      Spacer()
      Text("Start Reading")
        .font(.headline)
        .foregroundStyle(Palette.ink)
      Text("Say “Hey Luna” to ask about words")
        .font(.caption2)
        .foregroundStyle(Palette.leather)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }
}

// MARK: - Timeline plumbing (static)

private struct Entry: TimelineEntry { let date: Date }

private struct StaticProvider: TimelineProvider {
  func placeholder(in context: Context) -> Entry { Entry(date: .now) }
  func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
    completion(Entry(date: .now))
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
    completion(Timeline(entries: [Entry(date: .now)], policy: .never))
  }
}
