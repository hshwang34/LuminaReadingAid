//
// BookFactory.swift
//
// Shared book creation / merging logic used by both the automatic
// identification pipeline (BookIdentificationService) and the manual orphan
// linking flow (OrphanSessionLinkView). Extracted so the two callers can't
// drift apart — both need to resolve "this candidate from Open Library →
// either an existing Book in our store or a new one."
//
// The async remote-cover fetch is NOT part of this helper. Callers that want
// to populate Book.coverImageData from Open Library should trigger that as a
// separate step, because the cover-fetch lifetime differs by caller
// (background task in the identification pipeline, fire-and-forget in the
// orphan sheet).
//

import Foundation
import SwiftData
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum BookFactory {

  /// Creates a new `Book` from `candidate`, or merges into an existing one
  /// with the same ISBN-13 when present. Synchronous and pure with respect to
  /// the main actor's store — does no network I/O.
  ///
  /// - Parameters:
  ///   - candidate: The metadata candidate (Open Library or similar).
  ///   - modelContext: SwiftData context to insert/merge into.
  ///   - canonicalCoverData: JPEG-encoded canonical cover image to attach to
  ///     the book's `coverCanonicalImageData` field, if the book doesn't
  ///     already have one.
  ///   - ocrTitle: OCR-extracted title to stamp onto the book for future
  ///     fuzzy-match tiers. Nil-safe via empty string.
  ///   - ocrAuthor: Same, but for author.
  ///   - source: Human-readable identification-source tag, e.g.
  ///     `"openlibrary"` or `"openlibrary-manual"`. Stored on the book for
  ///     debugging / UX purposes.
  static func createOrUpdate(
    from candidate: BookMetadataCandidate,
    in modelContext: ModelContext,
    canonicalCoverData: Data?,
    ocrTitle: String,
    ocrAuthor: String,
    source: String
  ) -> Book {
    if let isbn = candidate.isbn13 {
      let descriptor = FetchDescriptor<Book>(
        predicate: #Predicate<Book> { $0.isbn13 == isbn }
      )
      if let existing = try? modelContext.fetch(descriptor).first {
        merge(candidate: candidate,
              into: existing,
              canonicalCoverData: canonicalCoverData,
              ocrTitle: ocrTitle,
              ocrAuthor: ocrAuthor,
              source: source)
        try? modelContext.save()
        return existing
      }
    }

    let book = Book(
      title: candidate.title,
      author: candidate.author,
      isbn13: candidate.isbn13,
      openLibraryWorkId: candidate.openLibraryWorkId,
      coverTitleOCR: ocrTitle,
      coverAuthorOCR: ocrAuthor,
      coverCanonicalImageData: canonicalCoverData,
      lastIdentifiedAt: Date(),
      identificationSource: source
    )
    modelContext.insert(book)
    try? modelContext.save()
    return book
  }

  private static func merge(
    candidate: BookMetadataCandidate,
    into book: Book,
    canonicalCoverData: Data?,
    ocrTitle: String,
    ocrAuthor: String,
    source: String
  ) {
    if book.openLibraryWorkId == nil { book.openLibraryWorkId = candidate.openLibraryWorkId }
    if (book.coverTitleOCR ?? "").isEmpty { book.coverTitleOCR = ocrTitle }
    if (book.coverAuthorOCR ?? "").isEmpty { book.coverAuthorOCR = ocrAuthor }
    if book.coverCanonicalImageData == nil, let canonicalCoverData {
      book.coverCanonicalImageData = canonicalCoverData
    }
    if book.identificationSource == nil { book.identificationSource = source }
    book.lastIdentifiedAt = Date()
  }
}

// MARK: - JPEG Encoding

/// Encodes a `CGImage` to JPEG data at 0.8 quality. Shared between
/// BookIdentificationService, OrphanSessionLinkView, and anywhere else that
/// needs to persist a cover image. Returns nil only on Core Graphics failure.
func jpegData(fromCGImage cgImage: CGImage) -> Data? {
  let data = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(
    data, UTType.jpeg.identifier as CFString, 1, nil
  ) else { return nil }
  let options: [CFString: Any] = [
    kCGImageDestinationLossyCompressionQuality: 0.8
  ]
  CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
  guard CGImageDestinationFinalize(destination) else { return nil }
  return data as Data
}
