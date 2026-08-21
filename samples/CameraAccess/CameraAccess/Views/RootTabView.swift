import SwiftUI
import MWDATCore

struct RootTabView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel

  var body: some View {
    TabView {
      NavigationStack {
        LibraryView(wearables: wearables, wearablesVM: wearablesVM)
      }
      .tabItem {
        Label("Library", systemImage: "books.vertical")
      }

      NavigationStack {
        WordsTabView()
      }
      .tabItem {
        Label("Words", systemImage: "textformat.abc")
      }

      NavigationStack {
        PracticeTabView()
      }
      .tabItem {
        Label("Practice", systemImage: "brain.head.profile")
      }

      NavigationStack {
        ProfileTabView()
      }
      .tabItem {
        Label("Profile", systemImage: "person.crop.circle")
      }

      #if DEBUG
      NavigationStack {
        AnswerHarnessView()
      }
      .tabItem {
        Label("Debug", systemImage: "ladybug")
      }
      #endif
    }
    .tint(.ink)
    // Nothing is pre-warmed at launch. The one model in the app — the llama.cpp
    // Qwen3 shared by the voice session and the utility work (quizzes, enrichment,
    // cover extraction) — loads at session start or first use, where the wait is
    // expected and visible. Warming a ~1GB model on every cold launch is a cost paid
    // by every user for a feature most launches never touch.
  }
}
