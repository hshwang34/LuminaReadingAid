import SwiftData
import Foundation

@Model
final class ReadingSession {
  var startedAt: Date
  var endedAt: Date?
  var startPage: Int?
  var endPage: Int?
  var book: Book?

  // MARK: - Failed-cover recovery state
  //
  // Populated by StreamSessionViewModel.recordFailedCoverAttempt when the
  // cover-identification pipeline terminates in a .failed state for this
  // session. The OrphanSessionLinkView presents these back to the user so
  // they can visually confirm which book they were reading before picking
  // one manually. The pHash is migrated onto the chosen Book so future
  // sessions can recover via BookIdentificationService's pHash tier.

  /// JPEG of the canonical (perspective-warped) cover image we tried to match.
  var coverAttemptImageData: Data?
  /// Perceptual hash of the failed attempt, as a 16-char hex string.
  var coverAttemptPHashHex: String?
  /// Raw OCR / Qwen title extracted from the failed attempt. Pre-fills the
  /// Open Library search field in the session-end orphan sheet.
  var coverAttemptOCRTitle: String?
  /// Raw OCR / Qwen author extracted from the failed attempt.
  var coverAttemptOCRAuthor: String?
  /// True once the session's single identification attempt has landed in a
  /// terminal non-matched state. The session-end sheet surfaces its link UI
  /// only when this is true *and* `book == nil`.
  var identificationFailed: Bool = false

  init(book: Book?) {
    self.startedAt = Date()
    self.book = book
  }
}
