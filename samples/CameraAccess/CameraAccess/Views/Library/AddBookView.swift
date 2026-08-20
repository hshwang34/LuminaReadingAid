import SwiftUI

struct AddBookView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @State private var title = ""
  @State private var author = ""

  var body: some View {
    NavigationStack {
      VStack(spacing: Spacing.xl) {
        VStack(spacing: Spacing.lg) {
          TextField("Book Title", text: $title)
            .font(.serif(.title3, weight: .semibold))
            .padding(Spacing.lg)
            .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))

          TextField("Author", text: $author)
            .font(.subheadline)
            .padding(Spacing.lg)
            .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
        }
        .padding(.horizontal, Spacing.lg)

        Spacer()
      }
      .padding(.top, Spacing.xl)
      .background(.parchment)
      .navigationTitle("Add Book")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .foregroundStyle(.leather)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add") {
            let book = Book(title: title, author: author)
            modelContext.insert(book)
            try? modelContext.save()
            dismiss()
          }
          .fontWeight(.semibold)
          .foregroundStyle(.ink)
          .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    }
  }
}
