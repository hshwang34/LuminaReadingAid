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

  init(text: String) {
    self.text = text
    self.capturedAt = Date()
  }
}

// MARK: - Shared Container

enum AppContainer {
  /// Single ModelContainer for the app. Created once and reused everywhere.
  static let shared: ModelContainer = {
    try! ModelContainer(for: CapturedWord.self)
  }()
}
