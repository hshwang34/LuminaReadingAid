import SwiftUI

// MARK: - Colors
//
// Defined on `ShapeStyle where Self == Color` so that `.ink`, `.parchment`, etc.
// work directly in `.background()`, `.foregroundStyle()`, `.stroke()` and any
// other modifier that accepts `some ShapeStyle` — not just `Color`.

extension ShapeStyle where Self == Color {
  /// Deep warm brown-black — like fountain pen ink. Primary text, buttons, active icons.
  static var ink: Color { Color(red: 61/255, green: 46/255, blue: 31/255) }
  /// Warm sienna — like leather book spines. Secondary text, section headers.
  static var leather: Color { Color(red: 122/255, green: 92/255, blue: 62/255) }
  /// Warm gold — like aged paper. Stars, progress bars, accent borders, badges.
  static var amber: Color { Color(red: 196/255, green: 149/255, blue: 106/255) }
  /// Warm cream — like a book page. Main app background.
  static var parchment: Color { Color(red: 247/255, green: 243/255, blue: 237/255) }
  /// Slightly warmer cream — card backgrounds, input fields, elevated surfaces.
  static var linen: Color { Color(red: 237/255, green: 232/255, blue: 223/255) }
  /// Muted brick red — error states, incorrect quiz answers.
  static var brick: Color { Color(red: 184/255, green: 92/255, blue: 74/255) }
  /// Sage green — correct quiz answers, positive feedback.
  static var sage: Color { Color(red: 107/255, green: 143/255, blue: 113/255) }
}

// MARK: - Typography

extension Font {
  /// Serif headline font — literary, elegant
  static func serif(_ style: TextStyle = .body, weight: Weight = .regular) -> Font {
    switch style {
    case .largeTitle:
      return .system(size: 34, weight: weight, design: .serif)
    case .title:
      return .system(size: 28, weight: weight, design: .serif)
    case .title2:
      return .system(size: 22, weight: weight, design: .serif)
    case .title3:
      return .system(size: 20, weight: weight, design: .serif)
    case .headline:
      return .system(size: 17, weight: .semibold, design: .serif)
    default:
      return .system(size: 17, weight: weight, design: .serif)
    }
  }

  /// Display — very large serif for word detail
  static let display = Font.system(size: 34, weight: .bold, design: .serif)
  /// Section title — serif bold
  static let sectionTitle = Font.system(size: 22, weight: .bold, design: .serif)
  /// Screen title — large serif bold
  static let screenTitle = Font.system(size: 28, weight: .bold, design: .serif)
}

// MARK: - Shadows

enum WarmShadow {
  case subtle
  case medium
  case cover

  var color: Color {
    Color(red: 61/255, green: 46/255, blue: 31/255)
  }

  var opacity: Double {
    switch self {
    case .subtle: 0.08
    case .medium: 0.12
    case .cover: 0.15
    }
  }

  var radius: CGFloat {
    switch self {
    case .subtle: 4
    case .medium: 8
    case .cover: 6
    }
  }

  var y: CGFloat {
    switch self {
    case .subtle: 2
    case .medium: 4
    case .cover: 4
    }
  }
}

extension View {
  func warmShadow(_ level: WarmShadow = .subtle) -> some View {
    shadow(color: level.color.opacity(level.opacity), radius: level.radius, y: level.y)
  }
}

// MARK: - Spacing

enum Spacing {
  static let xs: CGFloat = 4
  static let sm: CGFloat = 8
  static let md: CGFloat = 12
  static let lg: CGFloat = 16
  static let xl: CGFloat = 24
  static let xxl: CGFloat = 32
}

// MARK: - Corner Radius

enum CornerRadius {
  static let card: CGFloat = 12
  static let button: CGFloat = 12
  static let chip: CGFloat = 8
  static let cover: CGFloat = 8
  static let progress: CGFloat = 4
}
