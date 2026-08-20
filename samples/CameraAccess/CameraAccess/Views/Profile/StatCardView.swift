import SwiftUI

/// Small rounded card that surfaces one headline stat. Used on the Profile tab in
/// a two-column grid. Keeps the profile free of chart dependencies — big value,
/// small label, warm palette.
struct StatCardView: View {
  let icon: String
  let label: String
  let value: String
  var secondary: String? = nil
  var tint: Color = .ink

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: icon)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(tint)
        Text(label)
          .font(.caption)
          .foregroundStyle(.leather)
          .lineLimit(1)
      }
      Text(value)
        .font(.serif(.title2, weight: .bold))
        .foregroundStyle(.ink)
      if let secondary {
        Text(secondary)
          .font(.caption2)
          .foregroundStyle(.leather)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.md)
    .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
    .warmShadow()
  }
}
