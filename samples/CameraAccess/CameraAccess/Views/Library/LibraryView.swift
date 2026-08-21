import SwiftUI
import SwiftData

struct LibraryView: View {
  @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]
  @State private var showAddBook = false

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
      BookDetailView(book: book)
    }
    .sheet(isPresented: $showAddBook) {
      AddBookView()
    }
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.sectionTitle)
      .foregroundStyle(.ink)
      .padding(.horizontal, Spacing.lg)
  }
}
