import SwiftUI

struct BookCardView: View {
  let book: Book
  let style: Style

  enum Style {
    case large
    case compact
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      BookCoverView(imageData: book.coverImageData, size: style == .large ? .large : .compact)

      Text(book.title)
        .font(style == .large ? .headline : .subheadline)
        .foregroundStyle(.ink)
        .lineLimit(2)

      if style == .large, !book.author.isEmpty {
        Text(book.author)
          .font(.caption)
          .foregroundStyle(.leather)
      }

      if !book.words.isEmpty {
        Text("\(book.words.count) words")
          .font(.caption2)
          .foregroundStyle(.amber)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
          .background(.amber.opacity(0.15), in: RoundedRectangle(cornerRadius: CornerRadius.chip))
      }

      if let lastPage = book.lastReadPage {
        Text("p. \(lastPage)")
          .font(.caption2)
          .foregroundStyle(.leather)
      }
    }
    .frame(width: style == .large ? 140 : nil)
  }
}
