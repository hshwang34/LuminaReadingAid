//
// BookCoverOCRService.swift
//
// Two-stage extraction: Vision OCR collects raw lines from a canonical cover,
// then OnDeviceLLMService (Qwen2.5-1.5B) splits them into clean title + author.
// Falls back to raw-lines-as-title when Qwen isn't ready, so the pipeline
// never blocks on model download/warmup.
//

import Foundation
import CoreGraphics
import Vision

struct CoverOCRResult {
  let title: String
  let author: String
  let rawLines: [String]
  /// Qwen's raw output for debug display. Empty if LLM path was skipped.
  let llmRawOutput: String
}

final class BookCoverOCRService {

  private let textRequest: VNRecognizeTextRequest = {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    // Broader than word capture (en-US only) — covers carry many scripts.
    req.automaticallyDetectsLanguage = true
    return req
  }()

  init() {}

  /// Runs OCR on the canonical cover, then calls Qwen to split the raw lines
  /// into title + author. Returns raw-lines-as-title fallback if Qwen isn't
  /// ready or its extraction fails — the caller then uses Open Library's
  /// `q=` full-text parameter, which handles mixed input natively.
  func recognize(canonicalCover: CGImage) async throws -> CoverOCRResult {
    let rawLines = try runOCR(on: canonicalCover)
    guard !rawLines.isEmpty else {
      return CoverOCRResult(title: "", author: "", rawLines: [], llmRawOutput: "")
    }

    let llm = OnDeviceLLMService.shared
    if await llm.isReady {
      do {
        let fields = try await llm.extractCoverFields(ocrLines: rawLines)
        if !fields.title.isEmpty || !fields.author.isEmpty {
          return CoverOCRResult(
            title: fields.title,
            author: fields.author,
            rawLines: rawLines,
            llmRawOutput: fields.rawOutput
          )
        }
        #if DEBUG
        NSLog("[CoverOCR] Qwen returned empty fields — falling back to raw lines")
        #endif
        // Still propagate the raw output for debug visibility.
        return CoverOCRResult(
          title: rawLines.joined(separator: " "),
          author: "",
          rawLines: rawLines,
          llmRawOutput: fields.rawOutput
        )
      } catch {
        #if DEBUG
        NSLog("[CoverOCR] Qwen extractCoverFields failed: \(error) — falling back to raw lines")
        #endif
      }
    }

    return CoverOCRResult(
      title: rawLines.joined(separator: " "),
      author: "",
      rawLines: rawLines,
      llmRawOutput: ""
    )
  }

  // MARK: - Private

  private func runOCR(on cgImage: CGImage) throws -> [String] {
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try handler.perform([textRequest])

    guard let observations = textRequest.results, !observations.isEmpty else {
      return []
    }

    // Vision y-up: higher y = top of image. Sort top-to-bottom for Qwen.
    let sorted = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
    return sorted
      .compactMap { $0.topCandidates(1).first?.string }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}
