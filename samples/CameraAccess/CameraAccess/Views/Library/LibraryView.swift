import SwiftUI
import SwiftData

//
// LibraryView.swift
//
// The study shelf: books on one segment, every captured word on the other.
// Words live in book buckets — the flat list is the same data resliced, not a
// separate place — so both live under one roof. Session-starting lives on the
// Session tab, not here.
//

struct LibraryView: View {

  enum Segment: String, CaseIterable {
    case books = "Books"
    case words = "All Words"
  }

  @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]
  @State private var showAddBook = false
  @State private var segment: Segment = .books

  var body: some View {
    VStack(spacing: 0) {
      Picker("Section", selection: $segment) {
        ForEach(Segment.allCases, id: \.self) { segment in
          Text(segment.rawValue).tag(segment)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.sm)

      switch segment {
      case .books:
        booksContent
      case .words:
        WordsTabView()
      }
    }
    .background(.parchment)
    .navigationTitle("Library")
    .toolbar {
      if segment == .books {
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
    }
    .navigationDestination(for: Book.self) { book in
      BookDetailView(book: book)
    }
    .sheet(isPresented: $showAddBook) {
      AddBookView()
    }
  }

  // MARK: - Books

  private var booksContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.xl) {
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

        if books.isEmpty {
          ContentUnavailableView {
            Label("No books yet", systemImage: "books.vertical")
          } description: {
            Text("Ask Luna about words while you read — or add a book here to give them a home.")
          } actions: {
            Button("Add a Book") { showAddBook = true }
              .buttonStyle(.borderedProminent)
              .tint(.amber)
          }
          .padding(.top, Spacing.xxl)
        }
      }
      .padding(.vertical, Spacing.lg)
    }
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.sectionTitle)
      .foregroundStyle(.ink)
      .padding(.horizontal, Spacing.lg)
  }
}
