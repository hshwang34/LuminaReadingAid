import SwiftUI

/// GitHub-style contribution heatmap for reading activity.
/// Columns = weeks (oldest left → newest right). Rows = weekdays (Sun top → Sat bottom).
/// Shade intensity = activity-score bucket [0...4].
struct ReadingActivityCalendarView: View {
  /// Day-start date → activity score. Empty days are absent from the dict.
  let activity: [Date: Int]
  /// How many past weeks to show (inclusive of the current week).
  var weekCount: Int = 16
  var onTapDay: ((Date, Int) -> Void)? = nil

  private let calendar = Calendar.current
  private let cellSize: CGFloat = 14
  private let cellSpacing: CGFloat = 3

  private var weeks: [[Date]] {
    let today = calendar.startOfDay(for: Date())
    // Find the start of the week containing `today` (Sunday-first).
    let weekday = calendar.component(.weekday, from: today) // 1 = Sun
    guard let thisWeekStart = calendar.date(byAdding: .day, value: -(weekday - 1), to: today),
          let firstWeekStart = calendar.date(byAdding: .day, value: -7 * (weekCount - 1), to: thisWeekStart) else {
      return []
    }
    return (0..<weekCount).map { weekIdx in
      (0..<7).compactMap { dayIdx in
        calendar.date(byAdding: .day, value: weekIdx * 7 + dayIdx, to: firstWeekStart)
      }
    }
  }

  private var maxScore: Int {
    activity.values.max() ?? 0
  }

  private func bucket(for score: Int) -> Int {
    guard score > 0 else { return 0 }
    guard maxScore > 0 else { return 0 }
    // Log-ish 4-bucket shading based on max.
    let ratio = Double(score) / Double(maxScore)
    switch ratio {
    case ..<0.25: return 1
    case ..<0.5: return 2
    case ..<0.75: return 3
    default: return 4
    }
  }

  private func color(for bucket: Int) -> Color {
    switch bucket {
    case 0: return .linen
    case 1: return .amber.opacity(0.35)
    case 2: return .amber.opacity(0.6)
    case 3: return .amber.opacity(0.85)
    default: return .leather
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: cellSpacing) {
          ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
            VStack(spacing: cellSpacing) {
              ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                let dayStart = calendar.startOfDay(for: day)
                let score = activity[dayStart] ?? 0
                let isFuture = dayStart > calendar.startOfDay(for: Date())
                RoundedRectangle(cornerRadius: 3)
                  .fill(isFuture ? Color.linen.opacity(0.4) : color(for: bucket(for: score)))
                  .frame(width: cellSize, height: cellSize)
                  .overlay(
                    RoundedRectangle(cornerRadius: 3)
                      .stroke(Color.ink.opacity(0.06), lineWidth: 0.5)
                  )
                  .onTapGesture {
                    guard !isFuture else { return }
                    onTapDay?(dayStart, score)
                  }
              }
            }
          }
        }
        .padding(.vertical, 2)
      }

      // Legend
      HStack(spacing: Spacing.xs) {
        Text("Less")
          .font(.caption2)
          .foregroundStyle(.leather)
        ForEach(0..<5, id: \.self) { idx in
          RoundedRectangle(cornerRadius: 2)
            .fill(color(for: idx))
            .frame(width: 10, height: 10)
        }
        Text("More")
          .font(.caption2)
          .foregroundStyle(.leather)
      }
    }
  }
}
