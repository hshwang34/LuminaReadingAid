import SwiftUI

struct QuizView: View {
  @ObservedObject var viewModel: PracticeViewModel
  let quizType: QuizType
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      // Progress bar
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: CornerRadius.progress)
            .fill(.linen)
            .frame(height: 4)
          RoundedRectangle(cornerRadius: CornerRadius.progress)
            .fill(.amber)
            .frame(width: geo.size.width * viewModel.progress, height: 4)
            .animation(.easeOut(duration: 0.3), value: viewModel.progress)
        }
      }
      .frame(height: 4)
      .padding(.horizontal, Spacing.lg)
      .padding(.top, Spacing.sm)

      HStack {
        Button("End") { dismiss() }
          .font(.subheadline)
          .foregroundStyle(.leather)
        Spacer()
        if viewModel.currentQuestion != nil {
          Text("\(viewModel.currentIndex + 1) of \(viewModel.totalQuestionCount)")
            .font(.subheadline)
            .foregroundStyle(.leather)
        }
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.top, Spacing.sm)

      if viewModel.isGeneratingQuiz || viewModel.isWaitingForQuestion {
        Spacer()
        VStack(spacing: Spacing.md) {
          ProgressView()
            .tint(.amber)
          Text("Generating quiz\u{2026}")
            .font(.subheadline)
            .foregroundStyle(.leather)
        }
        Spacer()
      } else if viewModel.isFinished {
        QuizResultsView(viewModel: viewModel, quizType: quizType)
      } else if let question = viewModel.currentQuestion {
        questionContent(question)
      }

      Spacer()
    }
    .background(.parchment)
    .navigationBarBackButtonHidden()
  }

  @ViewBuilder
  private func questionContent(_ question: QuizQuestion) -> some View {
    VStack(spacing: Spacing.xl) {
      Spacer()

      // Prompt
      Text(question.style == .wordToDefinition
           ? "What does this word mean?"
           : "Which word matches this definition?")
        .font(.subheadline)
        .foregroundStyle(.leather)

      // Card
      VStack {
        Text(question.style == .wordToDefinition
             ? question.word.text
             : question.word.definition ?? "")
          .font(question.style == .wordToDefinition ? .headword : .system(.title3))
          .foregroundStyle(.ink)
          .multilineTextAlignment(.center)
          .padding(.horizontal, Spacing.lg)
          .italic(question.style == .definitionToWord)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, Spacing.xxl)
      .background(.linen, in: RoundedRectangle(cornerRadius: Spacing.lg))
      .warmShadow()
      .padding(.horizontal, Spacing.lg)

      // Options
      VStack(spacing: Spacing.md) {
        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
          answerButton(option, index: index, question: question)
        }
      }
      .padding(.horizontal, Spacing.lg)

      // Reinforcement + Next
      if viewModel.selectedAnswer != nil {
        if let def = viewModel.currentQuestion?.word.definition {
          VStack(spacing: Spacing.xs) {
            Text(viewModel.currentQuestion?.word.text ?? "")
              .font(.serif(.headline, weight: .bold))
              .foregroundStyle(.ink)
            Text(def)
              .font(.subheadline)
              .foregroundStyle(.leather)
            if let book = viewModel.currentQuestion?.word.book {
              Text(book.title)
                .font(.caption)
                .foregroundStyle(.leather.opacity(0.6))
            }
          }
          .padding(.top, Spacing.sm)
        }

        Button {
          viewModel.nextQuestion()
        } label: {
          Text(viewModel.currentIndex + 1 >= viewModel.totalQuestionCount ? "See Results" : "Next Word")
            .frame(maxWidth: .infinity)
            .padding(Spacing.lg)
            .background(.ink, in: RoundedRectangle(cornerRadius: CornerRadius.button))
            .foregroundStyle(.parchment)
            .font(.headline)
        }
        .padding(.horizontal, Spacing.lg)
      }

      Spacer()
    }
  }

  private func answerButton(_ text: String, index: Int, question: QuizQuestion) -> some View {
    let isSelected = viewModel.selectedAnswer == index
    let isCorrectAnswer = index == question.correctIndex
    let hasAnswered = viewModel.selectedAnswer != nil

    let backgroundColor: Color = {
      guard hasAnswered else { return .parchment }
      if isCorrectAnswer { return .sage.opacity(0.15) }
      if isSelected && !isCorrectAnswer { return .brick.opacity(0.15) }
      return .parchment
    }()

    let borderColor: Color = {
      guard hasAnswered else { return .ink.opacity(0.1) }
      if isCorrectAnswer { return .sage }
      if isSelected && !isCorrectAnswer { return .brick }
      return .ink.opacity(0.1)
    }()

    return Button {
      viewModel.selectAnswer(index)
    } label: {
      HStack {
        Text(["A", "B", "C", "D"][index])
          .font(.headline)
          .foregroundStyle(.leather)
          .frame(width: 24)
        Text(text)
          .font(.body)
          .foregroundStyle(.ink)
          .multilineTextAlignment(.leading)
        Spacer()
        if hasAnswered && isCorrectAnswer {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.sage)
        } else if hasAnswered && isSelected && !isCorrectAnswer {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.brick)
        }
      }
      .padding(Spacing.lg)
      .background(backgroundColor, in: RoundedRectangle(cornerRadius: CornerRadius.card))
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.card)
          .stroke(borderColor, lineWidth: 1.5)
      )
    }
    .buttonStyle(.plain)
    .disabled(hasAnswered)
  }
}
