import SwiftUI
import UIKit

// MARK: - Colors
//
// "Notebook Minimal" palette. Defined on `ShapeStyle where Self == Color` so that
// `.ink`, `.parchment`, etc. work directly in `.background()`, `.foregroundStyle()`,
// `.stroke()` and any other modifier that accepts `some ShapeStyle`.
//
// Token names are semantic roles kept from the original system (zero call-site
// churn): ink = primary, leather = secondary, amber = accent, parchment =
// background, linen = surface, brick = error, sage = success. Every token is
// dynamic — the dark values are first-class, not an inversion.

private func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
  func component(_ hex: UInt32, _ shift: UInt32) -> CGFloat {
    CGFloat((hex >> shift) & 0xFF) / 255
  }
  return Color(uiColor: UIColor { trait in
    let hex = trait.userInterfaceStyle == .dark ? dark : light
    return UIColor(
      red: component(hex, 16), green: component(hex, 8), blue: component(hex, 0), alpha: 1)
  })
}

extension ShapeStyle where Self == Color {
  /// Graphite — primary text, active icons, high-emphasis fills.
  static var ink: Color { dynamic(0x1C1B1A, 0xF2F1EF) }
  /// Slate — secondary text, captions, section headers.
  static var leather: Color { dynamic(0x6B6560, 0xA8A19A) }
  /// Marigold — the one accent: progress, stars, links, primary buttons, the glow.
  static var amber: Color { dynamic(0xCC8A3D, 0xE0A155) }
  /// Paper — main app background.
  static var parchment: Color { dynamic(0xFAF9F7, 0x141312) }
  /// Cloud — card and input surfaces.
  static var linen: Color { dynamic(0xF1EFEC, 0x211F1D) }
  /// Coral — error states, incorrect quiz answers.
  static var brick: Color { dynamic(0xD65F4C, 0xE8836F) }
  /// Moss — correct quiz answers, positive feedback.
  static var sage: Color { dynamic(0x5F8F6E, 0x83B892) }
  /// Card and separator borders — replaces shadows as the edge of a surface.
  static var hairline: Color { dynamic(0x1C1B1A, 0xF2F1EF).opacity(0.14) }
}

// MARK: - Typography
//
// Serif is rationed to two places — word headwords and the streak numeral — as a
// deliberate "dictionary" signal. Everything else is the system face; stats and
// scores use SF Rounded.

extension Font {
  /// Serif — reserved for vocabulary words themselves (and quoted book text).
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

  /// A word being studied, at full size — WordDetail, the session card, quiz prompts.
  static let headword = Font.system(size: 34, weight: .bold, design: .serif)
  /// Display — large sans for hero text.
  static let display = Font.system(size: 34, weight: .bold)
  /// Section title.
  static let sectionTitle = Font.system(size: 20, weight: .bold)
  /// Screen title.
  static let screenTitle = Font.system(size: 28, weight: .bold)
  /// Stats, scores, streaks — rounded digits read friendlier than default SF.
  static func stat(_ size: CGFloat = 22) -> Font {
    .system(size: size, weight: .bold, design: .rounded)
  }
}

// MARK: - Surfaces
//
// Notebook Minimal is flat: a surface is defined by its hairline border, not a
// drop shadow. `warmShadow` survives as API (dozens of call sites) but renders
// almost nothing — book covers keep a whisper of depth, cards none.

enum WarmShadow {
  case subtle
  case medium
  case cover

  var opacity: Double {
    switch self {
    case .subtle: 0
    case .medium: 0
    case .cover: 0.10
    }
  }

  var radius: CGFloat {
    switch self {
    case .subtle: 0
    case .medium: 0
    case .cover: 4
    }
  }

  var y: CGFloat {
    switch self {
    case .subtle: 0
    case .medium: 0
    case .cover: 2
    }
  }
}

extension View {
  @ViewBuilder
  func warmShadow(_ level: WarmShadow = .subtle) -> some View {
    if level.opacity > 0 {
      shadow(color: .black.opacity(level.opacity), radius: level.radius, y: level.y)
    } else {
      self
    }
  }

  /// The standard card treatment: cloud surface with a hairline edge.
  func hairlineCard(cornerRadius: CGFloat = CornerRadius.card) -> some View {
    background(.linen, in: RoundedRectangle(cornerRadius: cornerRadius))
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius)
          .strokeBorder(.hairline, lineWidth: 1)
      )
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
