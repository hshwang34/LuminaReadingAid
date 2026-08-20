import SwiftUI

struct BookCoverView: View {
  let imageData: Data?
  let size: Size

  enum Size {
    case large
    case compact
    case detail

    var dimensions: (width: CGFloat, height: CGFloat) {
      switch self {
      case .large: (120, 170)
      case .compact: (100, 140)
      case .detail: (160, 220)
      }
    }
  }

  var body: some View {
    if let imageData, let uiImage = UIImage(data: imageData) {
      Image(uiImage: uiImage)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: size.dimensions.width, height: size.dimensions.height)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.cover))
        .warmShadow(.cover)
    } else {
      RoundedRectangle(cornerRadius: CornerRadius.cover)
        .fill(
          LinearGradient(
            colors: [.ink.opacity(0.6), .amber.opacity(0.7)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .frame(width: size.dimensions.width, height: size.dimensions.height)
        .overlay {
          Image(systemName: "book.closed.fill")
            .font(.title)
            .foregroundStyle(.parchment.opacity(0.6))
        }
        .warmShadow(.cover)
    }
  }
}
