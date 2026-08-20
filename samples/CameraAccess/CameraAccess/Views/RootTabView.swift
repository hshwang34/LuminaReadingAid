import SwiftUI
import MWDATCore

struct RootTabView: View {
  let wearables: WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @State private var showModelReadyToast = false
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
    }
    .tint(.ink)
    .task {
      // Pre-warm the on-device LLM so AI features (word lookup, quiz
      // distractors, definition generation during capture) are instant on
      // first use. The actor dedupes via an isReady early-return, so this is
      // safe alongside the existing ensureModelLoaded call sites in
      // WordDetailView and StreamSessionViewModel.
      let alreadyReady = await OnDeviceLLMService.shared.isReady
      try? await OnDeviceLLMService.shared.ensureModelLoaded { _ in }
      if !alreadyReady, await OnDeviceLLMService.shared.isReady {
        withAnimation(.spring(duration: 0.4)) {
          showModelReadyToast = true
        }
        try? await Task.sleep(for: .seconds(3))
        withAnimation(.spring(duration: 0.4)) {
          showModelReadyToast = false
        }
      }
    }
    .overlay(alignment: .top) {
      if showModelReadyToast {
        HStack(spacing: 10) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.sage)
          Text("AI model ready")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.ink)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.linen, in: Capsule())
        .overlay(Capsule().stroke(.amber.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
  }
}
