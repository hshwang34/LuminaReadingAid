//
// CapturedWord.swift
//
// SwiftData model for a word captured by the pointing-and-dwell gesture.
//

import SwiftData
import Foundation

@Model
final class CapturedWord {
  var text: String
  var capturedAt: Date
  /// Original crop from the photo (before preprocessing).
  var imageData: Data?
  /// Preprocessed crop that was sent to OCR (upscaled + enhanced).
  var preprocessedImageData: Data?

  // Context from the surrounding text (sentences above the word on the same page)
  var contextPhrase: String?

  /// What the reader actually said when they asked about this word — "what does
  /// divine mean in she divines her way". Raw material for personalised examples:
  /// an example that echoes the reader's own phrasing lands better than a generic
  /// one, and this is the only place that phrasing is ever heard. Optional, so the
  /// SwiftData migration is automatic.
  var spokenUtterance: String?

  // Word enrichment (populated via LLM lookup)
  var definition: String?
  var pronunciation: String?
  var exampleSentence: String?

  // Learning & practice
  var isStarred: Bool = false
  var masteryLevel: Int = 0
  var nextReviewDate: Date?

  // Book association
  var book: Book?
  /// Page number at the time of capture, if the reading session had committed one.
  var pageNumber: Int?

  init(text: String, imageData: Data? = nil, preprocessedImageData: Data? = nil, contextPhrase: String? = nil, book: Book? = nil, pageNumber: Int? = nil) {
    self.text = text
    self.capturedAt = Date()
    self.imageData = imageData
    self.preprocessedImageData = preprocessedImageData
    self.contextPhrase = contextPhrase
    self.book = book
    self.pageNumber = pageNumber
  }
}

// MARK: - Shared Container

enum AppContainer {
  /// Single ModelContainer for the app. Created once and reused everywhere.
  static let shared: ModelContainer = {
    try! ModelContainer(for: Book.self, ReadingSession.self, CapturedWord.self, CapturedPassage.self, QuizResult.self)
  }()
}
