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
    // The MLX model is no longer pre-warmed at launch. Two reasons: the voice answer
    // path now loads its own llama.cpp model at session start (where the wait is
    // expected and visible), and warming a ~1GB model on every cold launch is a cost
    // paid by every user for a feature most launches never touch. The remaining MLX
    // call sites — quiz distractors and word enrichment — still load lazily on demand
    // until they move over to the AnswerEngine and MLX is removed entirely.
  }
}
