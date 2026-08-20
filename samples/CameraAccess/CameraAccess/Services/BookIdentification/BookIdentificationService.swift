//
// BookIdentificationService.swift
//
// Orchestrates the identification flow. Called from StreamSessionViewModel
// every time CoverDetector emits a CoverCandidate. Owns the async pipeline —
// perspective warp → Vision OCR → Qwen field extraction → local fuzzy match
// → Open Library fallback — plus SwiftData persistence and the published
// phase that UI overlays observe.
//

import Foundation
import SwiftData
import Combine
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

enum MatchConfidence: Equatable {
  case high
  case medium
  case low
}

enum IdentificationError: Equatable {
  case offline
  case noResults
  case modelNotReady
  case ocrEmpty
  case networkFailed
  case canonicalizationFailed
}

enum BookIdentificationPhase: Equatable {
  case idle
  case identifying
  case matched(Book, confidence: MatchConfidence)
  case needsDisambiguation([BookMetadataCandidate])
  case failed(IdentificationError)

  static func == (lhs: BookIdentificationPhase, rhs: BookIdentificationPhase) -> Bool {
    switch (lhs, rhs) {
    case (.idle, .idle): return true
    case (.identifying, .identifying): return true
    case let (.matched(lBook, lConf), .matched(rBook, rConf)):
      return lBook === rBook && lConf == rConf
    case let (.needsDisambiguation(l), .needsDisambiguation(r)):
      return l.count == r.count && zip(l, r).allSatisfy { $0 == $1 }
    case let (.failed(l), .failed(r)):
      return l == r
    default:
      return false
    }
  }
}

extension BookMetadataCandidate: Equatable {
  static func == (lhs: BookMetadataCandidate, rhs: BookMetadataCandidate) -> Bool {
    lhs.openLibraryWorkId == rhs.openLibraryWorkId && lhs.title == rhs.title
  }
}

#if DEBUG
/// Snapshot of the most recent cover identification attempt, surfaced to the
/// debug overlay so the user can see OCR output + Qwen output + which tier
/// produced the final match — without needing Xcode console attached.
struct CoverDebugSnapshot: Equatable {
  let capturedAt: Date
  let ocrRawLines: [String]
  let qwenRawOutput: String
  let qwenParsedTitle: String
  let qwenParsedAuthor: String
  /// Human-readable description of which tier produced the final match.
  /// e.g. "Tier 1: Qwen → OL auto-pick", "Tier 2: title+author fallback", "failed: offline"
  let matchOutcome: String
}
#endif

/// Metadata captured when an identification attempt terminates in a `.failed`
/// state. Published alongside `phase` so the view model can persist the
/// canonical cover + OCR hints onto the active ReadingSession without needing
/// the service to know about SwiftData lifecycle or ReadingSession specifically.
struct FailedCoverAttempt: Equatable {
  let canonicalCover: CGImage?
  let ocrTitle: String
  let ocrAuthor: String
  let reason: IdentificationError
  /// Monotonic timestamp. Two otherwise-identical failure snapshots are
  /// considered different if the time differs; this is what makes the
  /// struct safely Equatable despite holding a non-Equatable CGImage.
  let at: Date

  static func == (lhs: FailedCoverAttempt, rhs: FailedCoverAttempt) -> Bool {
    lhs.at == rhs.at && lhs.reason == rhs.reason
      && lhs.ocrTitle == rhs.ocrTitle && lhs.ocrAuthor == rhs.ocrAuthor
  }
}

@MainActor
final class BookIdentificationService: ObservableObject {

  @Published private(set) var phase: BookIdentificationPhase = .idle

  /// When true, further `submit()` calls are ignored and the view-model frame
  /// listener skips `CoverDetector.ingest(...)` entirely. Set to true on the
  /// first terminal state (success, failure, or disambiguation-needed) or via
  /// `lock(to:)` when the session starts with a pre-bound book. Cleared only
  /// by `resetForNewStream()`.
  @Published private(set) var isLockedToSession: Bool = false

  /// Metadata from the most recent failed identification attempt. Set by
  /// `commitFailure`, cleared by `resetForNewStream`. The ViewModel subscribes
  /// to `$phase` and reads this when the phase transitions to `.failed(...)`,
  /// persisting the canonical cover + OCR hints onto the active ReadingSession.
  @Published private(set) var lastFailedAttempt: FailedCoverAttempt?

  #if DEBUG
  /// Most recent cover identification attempt, for the on-screen debug overlay.
  /// Updated on every run of `runIdentification` regardless of outcome.
  @Published var lastCoverDebug: CoverDebugSnapshot?
  #endif

  private let modelContext: ModelContext
  private let ocrService: BookCoverOCRService
  private let metadataService: BookMetadataService
  private var activeTask: Task<Void, Never>?
  /// Thread-safe mirror of `isLockedToSession` so the video-frame closure can
  /// gate `CoverDetector.ingest(...)` without hopping to the main actor on every
  /// frame. Same pattern as `FlowBridge` in StreamSessionViewModel.
  private let lockBridge = LockBridge()
  /// Canonical cover + OCR metadata stashed by `commitDisambiguationNeeded`.
  /// Consumed either by `userPicked` (discarded) or `dismissDisambiguation`
  /// (turned into a failed-cover attempt).
  private var pendingDisambiguationCover: CGImage?
  private var pendingDisambiguationOCRTitle: String?
  private var pendingDisambiguationOCRAuthor: String?

  init(
    modelContext: ModelContext,
    ocrService: BookCoverOCRService = BookCoverOCRService(),
    metadataService: BookMetadataService = BookMetadataService()
  ) {
    self.modelContext = modelContext
    self.ocrService = ocrService
    self.metadataService = metadataService
  }

  // MARK: - Locking

  /// Pre-lock the service to a specific book without running identification.
  /// Call this from StreamSessionViewModel.init when the user pre-picked a book
  /// from the Library tab. After this call, the service rejects all cover
  /// candidates for the rest of the session and `phase` reflects a `.matched`
  /// state so UI observers see the binding immediately.
  func lock(to book: Book) {
    commitMatch(book, confidence: .high)
  }

  /// Thread-safe snapshot of the lock state for the video-frame closure.
  /// Never touches @Published state, so it's safe to call from a background queue.
  nonisolated func isLockedSnapshot() -> Bool {
    lockBridge.isLocked()
  }

  /// Single chokepoint for transitioning into `.matched` + flipping the lock.
  /// Every site inside `runIdentification` that would have written `phase = .matched(...)`
  /// goes through this helper instead.
  ///
  /// Also seeds `Book.coverPHashHex` the first time the book is matched, so the
  /// pHash recovery tier in future sessions has a reference to compare against.
  private func commitMatch(_ book: Book, confidence: MatchConfidence) {
    seedCoverPHashIfNeeded(for: book)
    phase = .matched(book, confidence: confidence)
    isLockedToSession = true
    lockBridge.setLocked(true)
  }

  /// Single chokepoint for terminal failure transitions. Runs the pHash
  /// recovery tier first — if the library has a known-good cover within a
  /// Hamming distance of 10, the session recovers and commits a match. Only
  /// when recovery misses does the failure actually commit, recording the
  /// canonical cover + OCR hints so the user can link it at session end.
  private func commitFailure(
    reason: IdentificationError,
    canonicalCover: CGImage?,
    ocrTitle: String,
    ocrAuthor: String
  ) {
    // Tier: perceptual-hash recovery. Runs only on failure paths, so the
    // happy path never pays the cost, but a genuine hard-to-OCR cover that
    // the user has seen before gets a second chance without any network or
    // LLM involvement.
    if let canonical = canonicalCover,
       let recovered = tryPerceptualHashRecovery(canonical: canonical) {
      recovered.lastIdentifiedAt = Date()
      try? modelContext.save()
      #if DEBUG
      NSLog("[BookID] ✓ pHash recovery (after \(reason)) → \"\(recovered.title)\"")
      #endif
      commitMatch(recovered, confidence: .medium)
      return
    }

    // No recovery — commit the terminal failure and store the snapshot.
    lastFailedAttempt = FailedCoverAttempt(
      canonicalCover: canonicalCover,
      ocrTitle: ocrTitle,
      ocrAuthor: ocrAuthor,
      reason: reason,
      at: Date()
    )
    phase = .failed(reason)
    isLockedToSession = true
    lockBridge.setLocked(true)
  }

  /// Single chokepoint for disambiguation-needed transitions. Locks the
  /// session so no new candidates are submitted while the user picks, but
  /// doesn't yet store a failed-cover record — that happens only if the user
  /// dismisses without picking (via `dismissDisambiguation`).
  private func commitDisambiguationNeeded(
    _ candidates: [BookMetadataCandidate],
    canonicalCover: CGImage?,
    ocrTitle: String,
    ocrAuthor: String
  ) {
    pendingDisambiguationCover = canonicalCover
    pendingDisambiguationOCRTitle = ocrTitle
    pendingDisambiguationOCRAuthor = ocrAuthor
    phase = .needsDisambiguation(candidates)
    isLockedToSession = true
    lockBridge.setLocked(true)
  }

  /// Tier: perceptual-hash recovery. Looks up every `Book.coverPHashHex` in
  /// the library and returns the closest match if the Hamming distance is
  /// ≤ 10 bits out of 64. 10 is the empirical "same image" cutoff for
  /// average-hash and tolerates lighting/glare/minor crop variation without
  /// producing false positives between genuinely different covers.
  private func tryPerceptualHashRecovery(canonical: CGImage) -> Book? {
    guard let candidateHash = PerceptualHash.hash(cgImage: canonical) else { return nil }
    let descriptor = FetchDescriptor<Book>(
      predicate: #Predicate<Book> { $0.coverPHashHex != nil }
    )
    guard let books = try? modelContext.fetch(descriptor) else { return nil }

    var best: (book: Book, distance: Int)?
    for book in books {
      guard let stored = book.coverPHashHex else { continue }
      let d = PerceptualHash.hammingDistance(candidateHash, stored)
      if best == nil || d < best!.distance {
        best = (book, d)
      }
    }
    guard let (book, distance) = best, distance <= 10 else { return nil }
    #if DEBUG
    NSLog("[BookID] pHash recovery candidate: \"%@\" distance=%d", book.title, distance)
    #endif
    return book
  }

  /// Computes and stores `book.coverPHashHex` from its canonical cover data
  /// if it doesn't already have one. Called on every successful match so
  /// the library's pHash index grows organically.
  private func seedCoverPHashIfNeeded(for book: Book) {
    guard book.coverPHashHex == nil,
          let data = book.coverCanonicalImageData,
          let provider = CGDataProvider(data: data as CFData),
          let cgImage = CGImage(
            jpegDataProviderSource: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ),
          let hash = PerceptualHash.hash(cgImage: cgImage) else {
      return
    }
    book.coverPHashHex = hash
    try? modelContext.save()
    #if DEBUG
    NSLog("[BookID] seeded coverPHashHex for \"\(book.title)\" = \(hash)")
    #endif
  }

  // MARK: - Submit

  /// Called from the video-frame thread after hopping to the main actor.
  /// Cancels any in-flight identification and starts a fresh one. Becomes a
  /// no-op once the session has been locked to a book, since one session is
  /// meant to bind to exactly one book.
  func submit(candidate: CoverCandidate) {
    guard !isLockedToSession else {
      #if DEBUG
      NSLog("[BookID] submit ignored — session already locked to a book")
      #endif
      return
    }
    #if DEBUG
    NSLog("[BookID] submit(candidate:) — starting identification")
    #endif
    activeTask?.cancel()
    activeTask = Task { [weak self] in
      guard let self else { return }
      await self.runIdentification(candidate: candidate)
    }
  }

  private func runIdentification(candidate: CoverCandidate) async {
    phase = .identifying
    #if DEBUG
    NSLog("[BookID] phase → .identifying")
    #endif

    // Debug snapshot state — populated at each stage, committed to
    // `lastCoverDebug` via `recordDebug()` at every terminal branch.
    var debugOCR: CoverOCRResult? = nil
    func recordDebug(outcome: String) {
      #if DEBUG
      self.lastCoverDebug = CoverDebugSnapshot(
        capturedAt: Date(),
        ocrRawLines: debugOCR?.rawLines ?? [],
        qwenRawOutput: debugOCR?.llmRawOutput ?? "",
        qwenParsedTitle: debugOCR?.title ?? "",
        qwenParsedAuthor: debugOCR?.author ?? "",
        matchOutcome: outcome
      )
      #endif
    }

    // 1. Perspective-warp to canonical upright cover.
    guard let canonical = CoverCanonicalizer.canonicalize(
      pixelBuffer: candidate.pixelBuffer,
      quad: candidate.quad
    ) else {
      #if DEBUG
      NSLog("[BookID] ❌ canonicalization failed")
      #endif
      recordDebug(outcome: "failed: canonicalization")
      commitFailure(reason: .canonicalizationFailed, canonicalCover: nil, ocrTitle: "", ocrAuthor: "")
      return
    }
    #if DEBUG
    NSLog("[BookID] ✓ canonicalized cover to %dx%d", canonical.width, canonical.height)
    #endif

    if Task.isCancelled { return }

    // 2. OCR + Qwen field extraction (with fallback when model not ready).
    let ocrResult: CoverOCRResult
    do {
      ocrResult = try await ocrService.recognize(canonicalCover: canonical)
    } catch {
      #if DEBUG
      NSLog("[BookID] ❌ OCR threw: \(error)")
      #endif
      recordDebug(outcome: "failed: OCR threw")
      commitFailure(reason: .ocrEmpty, canonicalCover: canonical, ocrTitle: "", ocrAuthor: "")
      return
    }
    debugOCR = ocrResult
    #if DEBUG
    NSLog("[BookID] ✓ OCR result — title=\"%@\" author=\"%@\" rawLines=%d",
          ocrResult.title, ocrResult.author, ocrResult.rawLines.count)
    #endif

    guard !ocrResult.title.trimmingCharacters(in: .whitespaces).isEmpty else {
      #if DEBUG
      NSLog("[BookID] ❌ OCR produced empty title")
      #endif
      recordDebug(outcome: "failed: empty title from OCR")
      commitFailure(reason: .ocrEmpty, canonicalCover: canonical, ocrTitle: ocrResult.title, ocrAuthor: ocrResult.author)
      return
    }

    if Task.isCancelled { return }

    // Clean + classified OCR lines for fallback searches.
    let trimmedLines = ocrResult.rawLines
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.count >= 3 }
    // "Long" lines are title candidates — typically ≥4 words or ≥18 chars.
    let longLines = trimmedLines
      .filter { $0.split(whereSeparator: { $0.isWhitespace }).count >= 3 || $0.count >= 18 }
      .sorted { $0.count > $1.count }
    // "Short proper-case" lines look like author names — 2–4 words, no digits.
    let authorCandidates = trimmedLines.filter { line in
      let words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
      guard words.count >= 2, words.count <= 4 else { return false }
      if line.rangeOfCharacter(from: .decimalDigits) != nil { return false }
      return true
    }
    // Raw-blob kept only for local fuzzy match (where it's still useful).
    let rawBlob = trimmedLines.joined(separator: " ")

    // 3. Local library fuzzy match — try Qwen's extraction first, then raw blob.
    if let match = tryLocalMatch(title: ocrResult.title, author: ocrResult.author) {
      #if DEBUG
      NSLog("[BookID] ✓ local match (Qwen): \"%@\" by %@", match.book.title, match.book.author)
      #endif
      match.book.lastIdentifiedAt = Date()
      try? modelContext.save()
      recordDebug(outcome: "Tier 1: Qwen → local match")
      commitMatch(match.book, confidence: match.confidence)
      return
    }
    if !rawBlob.isEmpty,
       let match = tryLocalMatch(title: rawBlob, author: "") {
      #if DEBUG
      NSLog("[BookID] ✓ local match (raw blob): \"%@\" by %@", match.book.title, match.book.author)
      #endif
      match.book.lastIdentifiedAt = Date()
      try? modelContext.save()
      recordDebug(outcome: "Tier 2: raw blob → local match")
      commitMatch(match.book, confidence: match.confidence)
      return
    }
    #if DEBUG
    NSLog("[BookID] no local match — querying Open Library")
    #endif

    if Task.isCancelled { return }

    // 4. Open Library search — primary (Qwen fields) + line-by-line fallback.
    var candidates: [BookMetadataCandidate] = []
    var scoringTitle = ocrResult.title
    var scoringAuthor = ocrResult.author
    // Track which tier produced the final candidates (for debug display).
    var searchTier: String = "Tier 1: Qwen → Open Library"

    do {
      candidates = try await metadataService.search(
        title: ocrResult.title,
        author: ocrResult.author
      )
    } catch BookMetadataService.MetadataError.offline {
      #if DEBUG
      NSLog("[BookID] ❌ offline")
      #endif
      recordDebug(outcome: "failed: offline")
      commitFailure(reason: .offline, canonicalCover: canonical, ocrTitle: ocrResult.title, ocrAuthor: ocrResult.author)
      return
    } catch BookMetadataService.MetadataError.noResults {
      #if DEBUG
      NSLog("[BookID] ⤵ primary search empty — trying line-by-line fallback")
      #endif
    } catch {
      #if DEBUG
      NSLog("[BookID] primary search failed: \(error) — trying line-by-line fallback")
      #endif
    }

    if Task.isCancelled { return }

    // Fallback tier 2: line-by-line search. Open Library's `q=` is a strict
    // keyword-AND match — more words = fewer results, not more — so we try
    // each candidate title line alone, pairing with likely author lines when
    // available. Stop at the first line that returns any hits.
    if candidates.isEmpty && !longLines.isEmpty {
      // Up to 3 title candidates × (paired with up to 2 author candidates + standalone)
      // = max 9 API calls per cover. Worst-case still polite to Open Library.
      let titleTries = longLines.prefix(3)

      searchLoop: for titleLine in titleTries {
        if Task.isCancelled { return }

        // First try: title line paired with each author candidate.
        for authorLine in authorCandidates.prefix(2) where authorLine != titleLine {
          #if DEBUG
          NSLog("[BookID] fallback: title=\"%@\" author=\"%@\"", titleLine, authorLine)
          #endif
          do {
            let found = try await metadataService.search(title: titleLine, author: authorLine)
            if !found.isEmpty {
              #if DEBUG
              NSLog("[BookID] ✓ fallback hit (title+author) — %d candidates", found.count)
              #endif
              candidates = found
              scoringTitle = titleLine
              scoringAuthor = authorLine
              searchTier = "Tier 2: line-by-line (title+author)"
              break searchLoop
            }
          } catch BookMetadataService.MetadataError.offline {
            recordDebug(outcome: "failed: offline")
            commitFailure(reason: .offline, canonicalCover: canonical, ocrTitle: ocrResult.title, ocrAuthor: ocrResult.author)
            return
          } catch {
            continue
          }
        }

        // Second try: title line alone.
        if Task.isCancelled { return }
        #if DEBUG
        NSLog("[BookID] fallback: title-only \"%@\"", titleLine)
        #endif
        do {
          let found = try await metadataService.search(title: titleLine, author: "")
          if !found.isEmpty {
            #if DEBUG
            NSLog("[BookID] ✓ fallback hit (title-only) — %d candidates", found.count)
            #endif
            candidates = found
            scoringTitle = titleLine
            scoringAuthor = ""
            searchTier = "Tier 2: line-by-line (title-only)"
            break searchLoop
          }
        } catch BookMetadataService.MetadataError.offline {
          recordDebug(outcome: "failed: offline")
          commitFailure(reason: .offline, canonicalCover: canonical, ocrTitle: ocrResult.title, ocrAuthor: ocrResult.author)
          return
        } catch {
          continue
        }
      }
    }

    if Task.isCancelled { return }

    guard !candidates.isEmpty else {
      #if DEBUG
      NSLog("[BookID] ❌ no results from any search path (Qwen / line-by-line)")
      #endif
      recordDebug(outcome: "failed: no Open Library results")
      commitFailure(reason: .noResults, canonicalCover: canonical, ocrTitle: ocrResult.title, ocrAuthor: ocrResult.author)
      return
    }
    #if DEBUG
    NSLog("[BookID] ✓ Open Library returned %d candidates", candidates.count)
    #endif

    // 5. Score and decide.
    let decision = CoverMatching.selectTopCandidate(
      candidates,
      ocrTitle: scoringTitle,
      ocrAuthor: scoringAuthor
    )

    if let auto = decision.auto {
      #if DEBUG
      NSLog("[BookID] ✅ auto-picked: \"%@\" (score %.3f)", auto.title, auto.fuzzyScore)
      #endif
      let book = createOrUpdateBook(
        from: auto,
        canonicalCoverImage: canonical,
        ocrTitle: ocrResult.title,
        ocrAuthor: ocrResult.author
      )
      recordDebug(outcome: "\(searchTier) → auto-pick")
      commitMatch(book, confidence: .high)
    } else {
      #if DEBUG
      NSLog("[BookID] ⚠️  disambiguation needed — %d options", decision.picker.count)
      #endif
      recordDebug(outcome: "\(searchTier) → disambiguation (\(decision.picker.count))")
      commitDisambiguationNeeded(
        decision.picker,
        canonicalCover: canonical,
        ocrTitle: ocrResult.title,
        ocrAuthor: ocrResult.author
      )
    }
  }

  // MARK: - Disambiguation

  func userPicked(_ candidate: BookMetadataCandidate) {
    guard case .needsDisambiguation = phase else { return }
    let book = createOrUpdateBook(
      from: candidate,
      canonicalCoverImage: nil,
      ocrTitle: candidate.title,
      ocrAuthor: candidate.author
    )
    commitMatch(book, confidence: .medium)
  }

  /// User dismissed the picker without selecting a candidate. Treat this as a
  /// terminal failure — the one-shot invariant says we don't try again, and the
  /// orphan-session flow will surface the stashed canonical cover so they can
  /// link it manually at session end.
  func dismissDisambiguation() {
    guard case .needsDisambiguation = phase else { return }
    let cover = pendingDisambiguationCover
    let title = pendingDisambiguationOCRTitle ?? ""
    let author = pendingDisambiguationOCRAuthor ?? ""
    pendingDisambiguationCover = nil
    pendingDisambiguationOCRTitle = nil
    pendingDisambiguationOCRAuthor = nil
    commitFailure(reason: .noResults, canonicalCover: cover, ocrTitle: title, ocrAuthor: author)
  }

  /// Clears all session state — in-flight task, phase, session lock, and the
  /// failed-attempt snapshot. Called from `StreamSessionViewModel.stopSession()`
  /// so the next session can run identification from a clean slate even if the
  /// service instance is reused.
  func resetForNewStream() {
    activeTask?.cancel()
    activeTask = nil
    phase = .idle
    isLockedToSession = false
    lockBridge.setLocked(false)
    lastFailedAttempt = nil
    pendingDisambiguationCover = nil
    pendingDisambiguationOCRTitle = nil
    pendingDisambiguationOCRAuthor = nil
  }

  // MARK: - Local match

  private func tryLocalMatch(title: String, author: String) -> (book: Book, confidence: MatchConfidence)? {
    let descriptor = FetchDescriptor<Book>()
    guard let books = try? modelContext.fetch(descriptor), !books.isEmpty else {
      return nil
    }
    guard let result = CoverMatching.localMatch(
      ocrTitle: title,
      ocrAuthor: author,
      books: books
    ) else {
      return nil
    }
    if result.score >= 0.85 {
      return (result.book, .high)
    } else if result.score >= 0.70 {
      return (result.book, .medium)
    }
    return nil
  }

  // MARK: - Book creation / update

  /// Delegates to the shared `BookFactory` helper and then fires off the
  /// async cover-image fetch. Kept as a thin wrapper so existing call sites
  /// inside `runIdentification` don't have to know about the helper.
  private func createOrUpdateBook(
    from candidate: BookMetadataCandidate,
    canonicalCoverImage: CGImage?,
    ocrTitle: String,
    ocrAuthor: String
  ) -> Book {
    let book = BookFactory.createOrUpdate(
      from: candidate,
      in: modelContext,
      canonicalCoverData: canonicalCoverImage.flatMap(jpegData(fromCGImage:)),
      ocrTitle: ocrTitle,
      ocrAuthor: ocrAuthor,
      source: "openlibrary"
    )
    fetchRemoteCoverIfNeeded(candidate: candidate, bookID: book.persistentModelID)
    return book
  }

  private func fetchRemoteCoverIfNeeded(
    candidate: BookMetadataCandidate,
    bookID: PersistentIdentifier
  ) {
    guard let coverURL = candidate.coverImageURL else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let data = try await self.metadataService.fetchCoverImage(coverURL)
        if let book = self.modelContext.model(for: bookID) as? Book,
           book.coverImageData == nil {
          book.coverImageData = data
          try? self.modelContext.save()
        }
      } catch {
        #if DEBUG
        NSLog("[BookID] cover fetch failed: \(error)")
        #endif
      }
    }
  }

}

// MARK: - LockBridge

/// NSLock-protected mirror of `BookIdentificationService.isLockedToSession` that
/// the video-frame listener can read from a background queue without touching
/// @Published state. Same pattern as `FlowBridge` in StreamSessionViewModel.
private final class LockBridge: @unchecked Sendable {
  private let lock = NSLock()
  private var locked: Bool = false

  func isLocked() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return locked
  }

  func setLocked(_ value: Bool) {
    lock.lock()
    defer { lock.unlock() }
    locked = value
  }
}
