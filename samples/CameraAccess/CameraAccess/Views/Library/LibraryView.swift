import MWDATCore
import SwiftUI
import SwiftData

struct LibraryView: View {
  let wearables: any WearablesInterface
  @ObservedObject var wearablesVM: WearablesViewModel
  @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]
  @State private var showAddBook = false
  @State private var showStreaming = false
  @State private var showPhoneCameraStreaming = false
  @State private var showVoiceSession = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.xl) {
        // Currently Reading
        let reading = books.filter { !$0.isFinished }
        if !reading.isEmpty {
          sectionHeader("Currently Reading")
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.lg) {
              ForEach(reading) { book in
                NavigationLink(value: book) {
                  BookCardView(book: book, style: .large)
                }
                .buttonStyle(.plain)
              }
            }
            .padding(.horizontal, Spacing.lg)
          }
        }

        // Finished
        let finished = books.filter { $0.isFinished }
        if !finished.isEmpty {
          sectionHeader("Finished")
          LazyVGrid(columns: [
            GridItem(.flexible(), spacing: Spacing.lg),
            GridItem(.flexible(), spacing: Spacing.lg)
          ], spacing: Spacing.lg) {
            ForEach(finished) { book in
              NavigationLink(value: book) {
                BookCardView(book: book, style: .compact)
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, Spacing.lg)
        }

        // Empty state
        if books.isEmpty {
          VStack(spacing: Spacing.lg) {
            Image(systemName: "books.vertical")
              .font(.system(size: 48))
              .foregroundStyle(.leather.opacity(0.3))
            Text("No books yet")
              .font(.sectionTitle)
              .foregroundStyle(.leather)
            Text("Start a voice session and ask Luna about words as you read, or add a book manually.")
              .font(.subheadline)
              .foregroundStyle(.leather.opacity(0.6))
              .multilineTextAlignment(.center)
          }
          .frame(maxWidth: .infinity)
          .padding(.top, 60)
          .padding(.horizontal, Spacing.xxl)
        }

        // Start a voice session — the app's primary action. Works with no book bound;
        // the session is linked to one at the end if it wasn't at the start.
        Divider()
          .padding(.horizontal, Spacing.lg)

        Button {
          showVoiceSession = true
        } label: {
          HStack {
            Image(systemName: "waveform.and.mic")
              .foregroundStyle(.parchment)
            Text("Start Voice Session")
              .font(.headline)
              .foregroundStyle(.parchment)
            Spacer()
            Image(systemName: "chevron.right")
              .font(.caption)
              .foregroundStyle(.parchment.opacity(0.7))
          }
          .padding(Spacing.lg)
          .background(.ink, in: RoundedRectangle(cornerRadius: CornerRadius.card))
          .warmShadow()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.lg)

        Button {
          if wearablesVM.registrationState == .registered || wearablesVM.hasMockDevice {
            showStreaming = true
          } else {
            wearablesVM.connectGlasses()
          }
        } label: {
          HStack {
            Image(systemName: "eyeglasses")
              .foregroundStyle(.ink)
            Text(wearablesVM.registrationState == .registered
                 ? "Start Reading"
                 : "Connect Glasses")
              .font(.headline)
              .foregroundStyle(.ink)
            Spacer()
            if wearablesVM.registrationState == .registering {
              ProgressView()
                .tint(.leather)
            } else {
              Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.leather)
            }
          }
          .padding(Spacing.lg)
          .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
          .warmShadow()
        }
        .buttonStyle(.plain)
        .disabled(wearablesVM.registrationState == .registering)
        .padding(.horizontal, Spacing.lg)

        Button {
          showPhoneCameraStreaming = true
        } label: {
          HStack {
            Image(systemName: "camera.fill")
              .foregroundStyle(.ink)
            Text("Use Phone Camera")
              .font(.headline)
              .foregroundStyle(.ink)
            Spacer()
            Image(systemName: "chevron.right")
              .font(.caption)
              .foregroundStyle(.leather)
          }
          .padding(Spacing.lg)
          .background(.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: CornerRadius.card))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.lg)
      }
      .padding(.vertical, Spacing.lg)
    }
    .background(.parchment)
    .navigationTitle("Library")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button { showAddBook = true } label: {
          Image(systemName: "plus")
            .foregroundStyle(.ink)
        }
      }
      #if DEBUG
      ToolbarItem(placement: .topBarLeading) {
        NavigationLink {
          CoverTestHarnessView()
        } label: {
          Image(systemName: "testtube.2")
            .foregroundStyle(.ink)
        }
      }
      #endif
    }
    .navigationDestination(for: Book.self) { book in
      BookDetailView(book: book, wearables: wearables, wearablesVM: wearablesVM)
    }
    .sheet(isPresented: $showAddBook) {
      AddBookView()
    }
    .fullScreenCover(isPresented: $showVoiceSession) {
      VoiceSessionView(book: nil)
    }
    .fullScreenCover(isPresented: $showStreaming) {
      StreamSessionView(wearables: wearables, wearablesVM: wearablesVM)
    }
    .fullScreenCover(isPresented: $showPhoneCameraStreaming) {
      StreamSessionView(wearables: wearables, wearablesVM: wearablesVM, cameraMode: .phoneCamera)
    }
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.sectionTitle)
      .foregroundStyle(.ink)
      .padding(.horizontal, Spacing.lg)
  }
}
