import SwiftUI

struct QuizResultsView: View {
  @ObservedObject var viewModel: PracticeViewModel
  let quizType: QuizType
  @Environment(\.dismiss) private var dismiss

  private var percentage: Int {
    guard viewModel.questions.count > 0 else { return 0 }
    return Int(Double(viewModel.score) / Double(viewModel.questions.count) * 100)
  }

  private var fillRatio: Double {
    Double(viewModel.score) / Double(max(viewModel.questions.count, 1))
  }

  var body: some View {
    VStack(spacing: Spacing.xxl) {
      Spacer()

      // Score circle
      ZStack {
        Circle()
          .stroke(.linen, lineWidth: 8)
        Circle()
          .trim(from: 0, to: fillRatio)
          .stroke(scoreColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .animation(.easeOut(duration: 0.6), value: fillRatio)
        VStack(spacing: Spacing.xs) {
          Text("\(viewModel.score)/\(viewModel.questions.count)")
            .font(.serif(.title, weight: .bold))
            .foregroundStyle(.ink)
          Text("\(percentage)%")
            .font(.subheadline)
            .foregroundStyle(.leather)
        }
      }
      .frame(width: 130, height: 130)

      Text(scoreMessage)
        .font(.sectionTitle)
        .foregroundStyle(.ink)
        .multilineTextAlignment(.center)

      Text(scoreSubtitle)
        .font(.subheadline)
        .foregroundStyle(.leather)
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.xxl)

      Spacer()

      Button {
        viewModel.saveResult(quizType: quizType)
        dismiss()
      } label: {
        Text("Done")
          .frame(maxWidth: .infinity)
          .padding(Spacing.lg)
          .background(.ink, in: RoundedRectangle(cornerRadius: CornerRadius.button))
          .foregroundStyle(.parchment)
          .font(.headline)
      }
      .padding(.horizontal, Spacing.lg)

      Spacer()
    }
    .padding(Spacing.lg)
    .background(.parchment)
  }

  private var scoreColor: Color {
    if percentage >= 80 { return .sage }
    if percentage >= 50 { return .amber }
    return .brick
  }

  private var scoreMessage: String {
    if percentage >= 80 { return "Great job!" }
    if percentage >= 50 { return "Keep practicing!" }
    return "Don't give up!"
  }

  private var scoreSubtitle: String {
    if percentage >= 80 { return "You're mastering these words. Keep up the momentum." }
    if percentage >= 50 { return "You're getting there. Review the tricky ones again." }
    return "Every expert was once a beginner. Try again tomorrow."
  }
}
