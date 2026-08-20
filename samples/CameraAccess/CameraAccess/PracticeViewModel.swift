import SwiftUI
import SwiftData

enum QuizType: String, CaseIterable {
  case dailyReview = "daily_review"
  case byBook = "by_book"
  case starred = "starred"
  case quickTen = "quick_ten"
}

enum QuizQuestionStyle {
  case wordToDefinition  // Show word, pick correct definition
  case definitionToWord  // Show definition, pick correct word
}

struct QuizQuestion {
  let word: CapturedWord
  let style: QuizQuestionStyle
  let options: [String]       // 4 options (one correct, three distractors)
  let correctIndex: Int
}

@MainActor
class PracticeViewModel: ObservableObject {
  @Published var questions: [QuizQuestion] = []
  @Published var currentIndex: Int = 0
  @Published var selectedAnswer: Int?
  @Published var score: Int = 0
  @Published var isFinished: Bool = false
  @Published var isGeneratingQuiz: Bool = false

  private var allWords: [CapturedWord] = []
  @Published private(set) var totalQuestionCount: Int = 0
  private var pendingWords: [CapturedWord] = []
  private var generationTask: Task<Void, Never>?
  private let modelContext: ModelContext = AppContainer.shared.mainContext

  var currentQuestion: QuizQuestion? {
    guard currentIndex < questions.count else { return nil }
    return questions[currentIndex]
  }

  /// True when user has reached a question that hasn't been generated yet.
  var isWaitingForQuestion: Bool {
    currentIndex >= questions.count && !isFinished
  }

  var progress: Double {
    guard totalQuestionCount > 0 else { return 0 }
    return Double(currentIndex) / Double(totalQuestionCount)
  }

  var isCorrect: Bool? {
    guard let selected = selectedAnswer, let question = currentQuestion else { return nil }
    return selected == question.correctIndex
  }

  func startQuiz(words: [CapturedWord], type: QuizType) async {
    // Filter to words that have definitions (required for quiz)
    let eligible = words.filter { $0.definition != nil }
    allWords = eligible

    let selected: [CapturedWord]
    switch type {
    case .dailyReview:
      let now = Date()
      selected = eligible.filter { word in
        guard let reviewDate = word.nextReviewDate else { return true }
        return reviewDate <= now
      }
    case .starred:
      selected = eligible.filter { $0.isStarred }
    case .quickTen:
      selected = Array(eligible.shuffled().prefix(10))
    case .byBook:
      selected = eligible // caller should pre-filter by book
    }

    let shuffledWords = selected.shuffled()
    totalQuestionCount = shuffledWords.count
    questions = []
    currentIndex = 0
    score = 0
    selectedAnswer = nil
    isFinished = false
    isGeneratingQuiz = true

    // Generate first 2 questions upfront so user can start immediately
    for word in shuffledWords.prefix(2) {
      if let q = await buildQuestion(for: word) {
        questions.append(q)
      }
    }

    isGeneratingQuiz = false
    pendingWords = Array(shuffledWords.dropFirst(2))

    // Generate remaining questions in the background
    generateRemainingQuestions()
  }

  private func generateRemainingQuestions() {
    generationTask = Task {
      for word in pendingWords {
        guard !Task.isCancelled else { break }
        if let q = await buildQuestion(for: word) {
          questions.append(q)
        }
      }
      pendingWords = []
    }
  }

  func selectAnswer(_ index: Int) {
    guard selectedAnswer == nil else { return } // No changing answers
    selectedAnswer = index
    if let question = currentQuestion, index == question.correctIndex {
      score += 1
    }
  }

  func nextQuestion() {
    guard let question = currentQuestion else { return }

    // Update spaced repetition
    let wasCorrect = selectedAnswer == question.correctIndex
    let result = SpacedRepetitionService.updateMastery(
      currentLevel: question.word.masteryLevel,
      wasCorrect: wasCorrect
    )
    question.word.masteryLevel = result.newLevel
    question.word.nextReviewDate = result.nextReview
    try? modelContext.save()

    // Advance
    currentIndex += 1
    selectedAnswer = nil
    if currentIndex >= totalQuestionCount {
      isFinished = true
      generationTask?.cancel()
    }
  }

  func saveResult(quizType: QuizType) {
    let quizResult = QuizResult(
      score: score,
      totalQuestions: questions.count,
      quizType: quizType.rawValue,
      words: questions.map(\.word)
    )
    modelContext.insert(quizResult)
    try? modelContext.save()
  }

  private func buildQuestion(for word: CapturedWord) async -> QuizQuestion? {
    guard let definition = word.definition else { return nil }

    // Alternate between word→def and def→word
    let style: QuizQuestionStyle = Bool.random() ? .wordToDefinition : .definitionToWord

    var options: [String]
    let correctAnswer: String

    switch style {
    case .wordToDefinition:
      correctAnswer = definition
      options = await llmDistractorDefinitions(word: word.text, definition: definition)
    case .definitionToWord:
      correctAnswer = word.text
      options = await llmDistractorWords(correctWord: word.text)
    }

    guard options.count >= 3 else { return nil }

    // Insert correct answer at random position
    let correctIndex = Int.random(in: 0...min(options.count, 3))
    options.insert(correctAnswer, at: correctIndex)
    options = Array(options.prefix(4))

    return QuizQuestion(word: word, style: style, options: options, correctIndex: correctIndex)
  }

  private func llmDistractorDefinitions(word: String, definition: String) async -> [String] {
    guard await OnDeviceLLMService.shared.isReady else { return [] }
    do {
      return try await OnDeviceLLMService.shared.generateQuizDistractors(
        word: word, correctDefinition: definition
      )
    } catch {
      return []
    }
  }

  private func llmDistractorWords(correctWord: String) async -> [String] {
    guard await OnDeviceLLMService.shared.isReady else { return [] }
    do {
      return try await OnDeviceLLMService.shared.generateQuizDistractorWords(
        correctWord: correctWord
      )
    } catch {
      return []
    }
  }
}
