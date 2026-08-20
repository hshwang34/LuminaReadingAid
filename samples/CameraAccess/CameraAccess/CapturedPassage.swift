//
// CapturedPassage.swift
//
// SwiftData model for a highlighted passage captured via the pinch-and-drag gesture.
//

import SwiftData
import Foundation

@Model
final class CapturedPassage {
  var text: String
  var capturedAt: Date
  /// JPEG of the cropped selection region from the perspective-corrected book page.
  var imageData: Data?
  /// The book this passage was captured from, if known.
  var book: Book?
  /// Page number at the time of capture, if the reading session had committed one.
  var pageNumber: Int?

  init(text: String, imageData: Data? = nil, book: Book? = nil, pageNumber: Int? = nil) {
    self.text = text
    self.capturedAt = Date()
    self.imageData = imageData
    self.book = book
    self.pageNumber = pageNumber
  }
}
