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

  init(text: String, imageData: Data? = nil, preprocessedImageData: Data? = nil) {
    self.text = text
    self.capturedAt = Date()
    self.imageData = imageData
    self.preprocessedImageData = preprocessedImageData
  }
}

// MARK: - Shared Container

enum AppContainer {
  /// Single ModelContainer for the app. Created once and reused everywhere.
  static let shared: ModelContainer = {
    try! ModelContainer(for: CapturedWord.self)
  }()
}
