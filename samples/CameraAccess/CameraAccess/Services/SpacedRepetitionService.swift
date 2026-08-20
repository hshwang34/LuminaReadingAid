import Foundation

enum SpacedRepetitionService {
  /// Intervals in days for each mastery level (0–5).
  private static let intervals: [Int] = [1, 2, 4, 7, 14, 30]

  /// Update mastery after a quiz answer.
  /// - Returns: The new mastery level and next review date.
  static func updateMastery(currentLevel: Int, wasCorrect: Bool) -> (newLevel: Int, nextReview: Date) {
    let newLevel: Int
    if wasCorrect {
      newLevel = min(currentLevel + 1, intervals.count - 1)
    } else {
      newLevel = max(currentLevel - 2, 0)
    }

    let daysUntilReview = intervals[newLevel]
    let nextReview = Calendar.current.date(byAdding: .day, value: daysUntilReview, to: Date())!

    return (newLevel, nextReview)
  }

  /// Generate distractor options for a multiple-choice quiz.
  /// Returns up to `count` definitions from other words, excluding the correct one.
  static func generateDistractors(
    correctWord: CapturedWord,
    allWords: [CapturedWord],
    count: Int = 3
  ) -> [CapturedWord] {
    let candidates = allWords.filter { word in
      word.persistentModelID != correctWord.persistentModelID && word.definition != nil
    }
    return Array(candidates.shuffled().prefix(count))
  }
}
