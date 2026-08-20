import SwiftData
import Foundation

@Model
final class QuizResult {
  var date: Date
  var score: Int
  var totalQuestions: Int
  var quizType: String

  @Relationship var words: [CapturedWord]

  init(score: Int, totalQuestions: Int, quizType: String, words: [CapturedWord] = []) {
    self.date = Date()
    self.score = score
    self.totalQuestions = totalQuestions
    self.quizType = quizType
    self.words = words
  }
}
