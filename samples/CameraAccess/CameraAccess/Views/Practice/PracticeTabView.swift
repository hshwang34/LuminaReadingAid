import SwiftUI
import SwiftData

struct PracticeTabView: View {
  @Query private var words: [CapturedWord]
  @StateObject private var quizVM = PracticeViewModel()
  @State private var activeQuizType: QuizType?

  private var dueForReview: Int {
    let now = Date()
    return words.filter { word in
      guard let reviewDate = word.nextReviewDate else {
        return word.definition != nil
      }
      return reviewDate <= now
    }.count
  }

  private var starredCount: Int {
    words.filter { $0.isStarred && $0.definition != nil }.count
  }

  private var totalWithDefinition: Int {
    words.filter { $0.definition != nil }.count
  }

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.lg) {
        // Progress card
        VStack(spacing: Spacing.sm) {
          Image(systemName: "chart.bar.fill")
            .font(.title2)
            .foregroundStyle(.amber)
          Text("\(words.count) words captured")
            .font(.headline)
            .foregroundStyle(.ink)
          Text("\(dueForReview) due for review")
            .font(.subheadline)
            .foregroundStyle(.leather)

          // Six bars, L0-L5 — the same mastery language as Profile's histogram,
          // teasing the system from the hub itself.
          masterySparkline
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
        .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
        .warmShadow()
        .padding(.horizontal, Spacing.lg)

        // Quiz options
        VStack(spacing: Spacing.md) {
          practiceCard(
            icon: "arrow.clockwise",
            title: "Daily Review",
            subtitle: "\(dueForReview) words due",
            color: .ink,
            disabled: dueForReview == 0
          ) {
            startQuiz(.dailyReview)
          }

          practiceCard(
            icon: "books.vertical",
            title: "Quiz by Book",
            subtitle: "Practice words from a specific book",
            color: .sage,
            disabled: totalWithDefinition == 0
          ) {
            startQuiz(.byBook)
          }

          practiceCard(
            icon: "star.fill",
            title: "Starred Words",
            subtitle: "\(starredCount) words",
            color: .amber,
            disabled: starredCount == 0
          ) {
            startQuiz(.starred)
          }

          practiceCard(
            icon: "target",
            title: "Quick 10",
            subtitle: "Random quick practice",
            color: .brick.opacity(0.8),
            disabled: totalWithDefinition < 4
          ) {
            startQuiz(.quickTen)
          }
        }
        .padding(.horizontal, Spacing.lg)

        if totalWithDefinition < 4 {
          Text("Capture and look up at least 4 words to start practicing.")
            .font(.caption)
            .foregroundStyle(.leather.opacity(0.6))
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.xxl)
            .padding(.top, Spacing.sm)
        }
      }
      .padding(.vertical, Spacing.lg)
    }
    .background(.parchment)
    .navigationTitle("Practice")
    .fullScreenCover(item: $activeQuizType) { type in
      NavigationStack {
        QuizView(viewModel: quizVM, quizType: type)
      }
    }
  }

  private var masterySparkline: some View {
    let buckets = (0...5).map { level in words.filter { $0.masteryLevel == level }.count }
    let maxBucket = max(buckets.max() ?? 0, 1)
    return HStack(alignment: .bottom, spacing: Spacing.xs) {
      ForEach(0..<buckets.count, id: \.self) { level in
        RoundedRectangle(cornerRadius: 2)
          .fill(level == 5 ? .sage : .amber.opacity(0.35 + 0.13 * Double(level)))
          .frame(width: 14, height: max(4, 28 * CGFloat(buckets[level]) / CGFloat(maxBucket)))
      }
    }
    .padding(.top, Spacing.xs)
    .accessibilityLabel("Mastery distribution")
  }

  private func startQuiz(_ type: QuizType) {
    activeQuizType = type
    Task { await quizVM.startQuiz(words: Array(words), type: type) }
  }

  private func practiceCard(icon: String, title: String, subtitle: String, color: Color, disabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: Spacing.lg) {
        Image(systemName: icon)
          .font(.title2)
          .foregroundStyle(disabled ? .leather.opacity(0.3) : color)
          .frame(width: 32)

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(title)
            .font(.headline)
            .foregroundStyle(.ink)
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.leather)
        }

        Spacer()

        Image(systemName: "chevron.right")
          .font(.caption)
          .foregroundStyle(.leather.opacity(0.5))
      }
      .padding(Spacing.lg)
      .background(.linen, in: RoundedRectangle(cornerRadius: CornerRadius.card))
      .warmShadow()
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .opacity(disabled ? 0.5 : 1)
  }
}

extension QuizType: Identifiable {
  var id: String { rawValue }
}
