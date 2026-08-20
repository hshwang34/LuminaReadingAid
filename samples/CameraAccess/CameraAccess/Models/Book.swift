import SwiftData
import Foundation
import CoreGraphics

@Model
final class Book {
  var title: String
  var author: String
  var coverImageData: Data?
  var dateAdded: Date
  var isFinished: Bool

  /// Most recently committed page number across all reading sessions. Shown on book cards.
  var lastReadPage: Int?

  /// Learned page-number location within this book's page layout. Once populated,
  /// periodic scans OCR only this tight region instead of full top/bottom margins.
  var pageNumberROI: PageNumberROI?

  /// 64-bit perceptual hash of this book's canonical cover, stored as a 16-char
  /// hex string. Populated when the book is first successfully identified (in
  /// `BookIdentificationService.commitMatch`) or when the user manually links
  /// an orphaned session to this book (in `OrphanSessionLinkView`). Used by the
  /// pHash recovery tier to match future covers against the library's known
  /// set before committing a terminal failure.
  var coverPHashHex: String?

  var isbn13: String?
  var openLibraryWorkId: String?
  var coverTitleOCR: String?
  var coverAuthorOCR: String?
  var coverCanonicalImageData: Data?
  var lastIdentifiedAt: Date?
  var identificationSource: String?

  @Relationship(deleteRule: .cascade, inverse: \CapturedWord.book)
  var words: [CapturedWord]

  @Relationship(deleteRule: .cascade, inverse: \CapturedPassage.book)
  var passages: [CapturedPassage]

  @Relationship(deleteRule: .cascade, inverse: \ReadingSession.book)
  var sessions: [ReadingSession]

  init(
    title: String,
    author: String,
    coverImageData: Data? = nil,
    isbn13: String? = nil,
    openLibraryWorkId: String? = nil,
    coverTitleOCR: String? = nil,
    coverAuthorOCR: String? = nil,
    coverCanonicalImageData: Data? = nil,
    lastIdentifiedAt: Date? = nil,
    identificationSource: String? = nil
  ) {
    self.title = title
    self.author = author
    self.coverImageData = coverImageData
    self.dateAdded = Date()
    self.isFinished = false
    self.isbn13 = isbn13
    self.openLibraryWorkId = openLibraryWorkId
    self.coverTitleOCR = coverTitleOCR
    self.coverAuthorOCR = coverAuthorOCR
    self.coverCanonicalImageData = coverCanonicalImageData
    self.lastIdentifiedAt = lastIdentifiedAt
    self.identificationSource = identificationSource
    self.words = []
    self.passages = []
    self.sessions = []
  }
}

/// Normalized page-number ROI in **left-page column-local coordinates**.
///
/// `rect` is (x, y, w, h) in [0,1] within a single page column, with y increasing
/// downward (0 = top of column, 1 = bottom). By convention we store the left-page
/// position; for the right page of a two-page spread the ROI is mirrored across
/// the spine (x → 1 - x - width) at scan time. This assumes books place page
/// numbers symmetrically on facing pages, which covers outer-margin and centered
/// layouts — by far the common case.
///
/// The enum and per-side field are gone on purpose: both sides contribute to
/// learning and both sides are read in locked mode.
struct PageNumberROI: Codable {
  var rect: CGRect
  /// Consecutive scans where locked-mode OCR produced no digit. Reset on success.
  /// When this crosses a threshold in the view-model, the ROI is cleared and
  /// learning restarts.
  var missStreak: Int
}
