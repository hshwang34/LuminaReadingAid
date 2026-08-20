import Foundation
import SwiftData

enum ReadingStatsService {

  // MARK: - Per-book pages

  /// Pages read across all committed sessions for a book. Each session contributes
  /// `max(0, endPage - startPage)` when both are known. Falls back to
  /// `lastReadPage` when no session has a committed range yet.
  static func pagesRead(for book: Book) -> Int {
    let summed = book.sessions.reduce(0) { acc, session in
      guard let start = session.startPage, let end = session.endPage, end > start else {
        return acc
      }
      return acc + (end - start)
    }
    if summed > 0 { return summed }
    return book.lastReadPage ?? 0
  }

  // MARK: - Reading time

  static func totalReadingTime(sessions: [ReadingSession]) -> TimeInterval {
    sessions.reduce(0) { acc, session in
      guard let end = session.endedAt else { return acc }
      let delta = end.timeIntervalSince(session.startedAt)
      return acc + max(0, delta)
    }
  }

  // MARK: - Activity map

  /// Day → activity score. Score = words captured + passages captured
  /// + quiz questions answered + reading minutes (floored).
  static func activityMap(
    words: [CapturedWord],
    passages: [CapturedPassage],
    sessions: [ReadingSession],
    quizzes: [QuizResult],
    calendar: Calendar = .current
  ) -> [Date: Int] {
    var map: [Date: Int] = [:]
    func bump(_ date: Date, by amount: Int) {
      guard amount > 0 else { return }
      let day = calendar.startOfDay(for: date)
      map[day, default: 0] += amount
    }
    for w in words { bump(w.capturedAt, by: 1) }
    for p in passages { bump(p.capturedAt, by: 1) }
    for q in quizzes { bump(q.date, by: q.totalQuestions) }
    for s in sessions {
      let end = s.endedAt ?? s.startedAt
      let minutes = Int(max(0, end.timeIntervalSince(s.startedAt)) / 60)
      bump(s.startedAt, by: minutes)
    }
    return map
  }

  // MARK: - Streak

  /// Longest consecutive run of days ending today (or yesterday, if today is empty)
  /// with non-zero activity.
  static func currentStreak(activityMap: [Date: Int], now: Date = Date(), calendar: Calendar = .current) -> Int {
    let today = calendar.startOfDay(for: now)
    var cursor: Date
    if (activityMap[today] ?? 0) > 0 {
      cursor = today
    } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              (activityMap[yesterday] ?? 0) > 0 {
      cursor = yesterday
    } else {
      return 0
    }
    var count = 0
    while (activityMap[cursor] ?? 0) > 0 {
      count += 1
      guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
      cursor = prev
    }
    return count
  }

  // MARK: - Mastery histogram

  /// 6-bucket histogram (levels 0–5) of how many captured words sit at each mastery level.
  /// Only counts words that have a definition (eligible for practice).
  static func masteryHistogram(words: [CapturedWord]) -> [Int] {
    var buckets = Array(repeating: 0, count: 6)
    for w in words where w.definition != nil {
      let level = min(max(w.masteryLevel, 0), 5)
      buckets[level] += 1
    }
    return buckets
  }

  // MARK: - Quiz accuracy

  /// Lifetime accuracy across all quizzes, or nil if none recorded.
  static func accuracy(quizzes: [QuizResult]) -> Double? {
    let totals = quizzes.reduce(into: (correct: 0, total: 0)) { acc, q in
      acc.correct += q.score
      acc.total += q.totalQuestions
    }
    guard totals.total > 0 else { return nil }
    return Double(totals.correct) / Double(totals.total)
  }

  // MARK: - Due for review today

  static func dueForReview(words: [CapturedWord], now: Date = Date()) -> Int {
    words.filter { word in
      guard word.definition != nil else { return false }
      guard let next = word.nextReviewDate else { return true }
      return next <= now
    }.count
  }

  // MARK: - Formatting helpers

  static func formatDuration(_ interval: TimeInterval) -> String {
    let totalMinutes = Int(interval / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours == 0 { return "\(minutes)m" }
    if minutes == 0 { return "\(hours)h" }
    return "\(hours)h \(minutes)m"
  }
}
