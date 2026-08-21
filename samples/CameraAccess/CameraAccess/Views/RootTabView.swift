import SwiftUI

//
// RootTabView.swift
//
// Session-first: tab 1 IS the live voice session. There is no start button and
// no session cover anywhere — opening the app is the start gesture, and the
// other tabs are the study side of the product (library, practice, profile).
//

struct RootTabView: View {

  let sessionController: VoiceSessionController

  enum Tab: Hashable {
    case session, library, practice, profile, debug
  }

  @State private var selection: Tab = .session
  @State private var launchRouter = SessionLaunchRouter.shared
  @AppStorage(OnboardingViewModel.hasCompletedKey) private var hasCompletedOnboarding = false

  var body: some View {
    TabView(selection: $selection) {
      SessionTabView(controller: sessionController)
        .tabItem {
          Label("Session", systemImage: "waveform.and.mic")
        }
        .tag(Tab.session)

      NavigationStack {
        LibraryView()
      }
      .tabItem {
        Label("Library", systemImage: "books.vertical")
      }
      .tag(Tab.library)

      NavigationStack {
        PracticeTabView()
      }
      .tabItem {
        Label("Practice", systemImage: "brain.head.profile")
      }
      .tag(Tab.practice)

      NavigationStack {
        ProfileTabView()
      }
      .tabItem {
        Label("Profile", systemImage: "person.crop.circle")
      }
      .tag(Tab.profile)

      #if DEBUG
      NavigationStack {
        AnswerHarnessView()
      }
      .tabItem {
        Label("Debug", systemImage: "ladybug")
      }
      .tag(Tab.debug)
      #endif
    }
    .tint(.amber)
    // External session requests — the App Intent, the URL scheme, Book Detail's
    // "Read This Book". All of them resolve to: show the Session tab, make sure
    // a session is running, bind the book if one was named.
    .onChange(of: launchRouter.pendingLaunch) { _, pending in
      guard pending else { return }
      consumeLaunchIfReady()
    }
    // A launch that arrived before onboarding finished is held, not dropped —
    // it fires the moment the gate opens.
    .onChange(of: hasCompletedOnboarding) { _, _ in
      consumeLaunchIfReady()
    }
    .task {
      consumeLaunchIfReady()
    }
    // Nothing is pre-warmed at launch beyond the session's own start path. The
    // one model in the app — the llama.cpp Qwen3 shared by the voice session and
    // the utility work — loads behind the session's listening state.
  }

  private func consumeLaunchIfReady() {
    guard launchRouter.pendingLaunch, hasCompletedOnboarding else { return }
    let book = launchRouter.pendingBook
    launchRouter.consume()
    selection = .session

    Task {
      if !sessionController.phase.isActive {
        await sessionController.start(book: book)
      }
      // Covers both the already-running case and losing the start race to the
      // Session tab's own auto-start (which binds no book).
      if let book, sessionController.book !== book {
        sessionController.bind(book: book)
      }
    }
  }
}
