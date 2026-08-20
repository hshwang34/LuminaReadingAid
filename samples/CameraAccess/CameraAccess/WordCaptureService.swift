//
// WordCaptureService.swift
//
// Crops the region above the fingertip, preprocesses it for maximum OCR quality,
// then extracts all recognized text within that region.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Vision
import UIKit

struct WordCaptureResult {
  /// All text recognized in the crop region, observations joined by space. Empty if nothing found.
  let text: String
  /// Original crop before any processing.
  let originalCrop: UIImage?
  /// Preprocessed crop that was sent to OCR (upscaled + enhanced).
  let preprocessedCrop: UIImage?
}

struct WordInContextResult {
  /// The word closest to the fingertip.
  let word: String
  /// All recognized text in reading order (context for LLM).
  let contextPhrase: String
  /// Tight crop of just the word's bounding box.
  let wordImage: UIImage?
  /// The full context region crop.
  let contextImage: UIImage?
}

final class WordCaptureService {

  // GPU-backed CIContext with color management disabled — OCR doesn't need color accuracy
  private let ciContext = CIContext(options: [
    .useSoftwareRenderer: false,
    .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
    .outputColorSpace: CGColorSpaceCreateDeviceRGB(),
  ])

  // Reusable OCR request — avoids per-call allocation and potential model reload
  private let textRequest: VNRecognizeTextRequest = {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    req.recognitionLanguages = ["en-US"]
    return req
  }()

  // MARK: - Public API

  /// Crops `cropRect` from `image`, preprocesses the crop, then runs OCR on it.
  /// Returns all recognized text and the preprocessed thumbnail.
  func recognizeWord(in image: UIImage, cropRect: CGRect) async -> WordCaptureResult {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self else {
          continuation.resume(returning: WordCaptureResult(text: "", originalCrop: nil, preprocessedCrop: nil))
          return
        }

        // Step 1: Crop using CIImage — avoids full-image UIGraphicsImageRenderer redraw for orientation
        guard let originalCrop = Self.cropImage(image: image, visionRect: cropRect) else {
          #if DEBUG
          NSLog("[OCR] crop failed")
          #endif
          continuation.resume(returning: WordCaptureResult(text: "", originalCrop: nil, preprocessedCrop: nil))
          return
        }
        #if DEBUG
        NSLog("[OCR] original crop size: %.0fx%.0f", originalCrop.size.width, originalCrop.size.height)
        #endif

        // Step 2: Preprocess — upscale 2x, document enhance, sharpen
        guard let preprocessedCG = self.preprocess(originalCrop) else {
          #if DEBUG
          NSLog("[OCR] preprocessing failed, using raw crop for OCR")
          #endif
          continuation.resume(returning: WordCaptureResult(text: "", originalCrop: originalCrop, preprocessedCrop: nil))
          return
        }
        let preprocessedCrop = UIImage(cgImage: preprocessedCG)
        #if DEBUG
        NSLog("[OCR] preprocessed size: %.0fx%.0f", preprocessedCrop.size.width, preprocessedCrop.size.height)
        #endif

        // Step 3: Run OCR on the preprocessed crop, then normalize.
        // This tight-crop path typically yields a single word, but OCR can glue
        // neighbors or attach punctuation — the normalizer handles both.
        let rawText = self.runOCR(on: preprocessedCG)
        let recognizedText = WordNormalizer.normalize(rawText) ?? ""

        #if DEBUG
        NSLog("[OCR] raw: \"%@\" normalized: \"%@\"", rawText, recognizedText)
        #endif
        continuation.resume(returning: WordCaptureResult(
          text: recognizedText,
          originalCrop: originalCrop,
          preprocessedCrop: preprocessedCrop
        ))
      }
    }
  }

  /// Runs OCR on a pre-extracted upright context image and identifies the word closest to the fingertip.
  ///
  /// - Parameters:
  ///   - contextImage: Upright UIImage produced by `OrientedCrop.extractUpright(from:)` — already
  ///                   rotated so text is horizontal, already cropped to the context region.
  ///   - fingerTipInCrop: Fingertip position in the context image's local Vision normalized coords
  ///                      (0–1, bottom-left origin). Typically near `y = 0` since the context crop
  ///                      extends upward from the fingertip.
  func recognizeWordInContext(
    contextImage: UIImage,
    fingerTipInCrop: CGPoint
  ) async -> WordInContextResult {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self else {
          continuation.resume(returning: WordInContextResult(word: "", contextPhrase: "", wordImage: nil, contextImage: nil))
          return
        }

        // Preprocess the upright context crop directly — no initial cropping step needed.
        guard let preprocessedCG = self.preprocess(contextImage) else {
          continuation.resume(returning: WordInContextResult(word: "", contextPhrase: "", wordImage: contextImage, contextImage: contextImage))
          return
        }

        // Run OCR
        let handler = VNImageRequestHandler(cgImage: preprocessedCG)
        try? handler.perform([self.textRequest])

        guard let observations = self.textRequest.results, !observations.isEmpty else {
          #if DEBUG
          NSLog("[WordContext] no text found in context region")
          #endif
          continuation.resume(returning: WordInContextResult(word: "", contextPhrase: "", wordImage: contextImage, contextImage: contextImage))
          return
        }

        // Fingertip already in crop-local coords; pass through as-is.
        let localTipX = fingerTipInCrop.x
        let localTipY = fingerTipInCrop.y

        // Flatten all observations to word-level bounding boxes.
        struct WordBox {
          let text: String
          let box: CGRect  // crop-local Vision coords
        }
        var allWords: [WordBox] = []
        for obs in observations {
          guard let candidate = obs.topCandidates(1).first else { continue }
          let lineText = candidate.string
          var idx = lineText.startIndex
          while idx < lineText.endIndex {
            while idx < lineText.endIndex, lineText[idx].isWhitespace {
              idx = lineText.index(after: idx)
            }
            guard idx < lineText.endIndex else { break }
            let wordStart = idx
            while idx < lineText.endIndex, !lineText[idx].isWhitespace {
              idx = lineText.index(after: idx)
            }
            let wordEnd = idx
            let range = wordStart..<wordEnd
            let wordText = String(lineText[range])
            if wordText.isEmpty { continue }
            if let rectObs = try? candidate.boundingBox(for: range) {
              allWords.append(WordBox(text: wordText, box: rectObs.boundingBox))
            }
          }
        }

        // Pick the target word: bottom proximity (word just above the fingertip) + horizontal distance.
        func score(_ w: WordBox) -> CGFloat {
          let bottomScore = abs(w.box.minY - localTipY)
          let horizontalDist: CGFloat
          if localTipX >= w.box.minX && localTipX <= w.box.maxX {
            horizontalDist = 0
          } else {
            horizontalDist = min(abs(localTipX - w.box.minX), abs(localTipX - w.box.maxX))
          }
          return bottomScore * 3.0 + horizontalDist
        }

        let targetWordBox = allWords.min(by: { score($0) < score($1) })
        let targetWord = WordNormalizer.normalize(targetWordBox?.text ?? "") ?? ""

        // Context phrase in reading order (keeps punctuation/capitalization for LLM context).
        let sorted = observations.sorted {
          let aMidY = $0.boundingBox.midY
          let bMidY = $1.boundingBox.midY
          if abs(aMidY - bMidY) > 0.02 {
            return aMidY > bMidY
          }
          return $0.boundingBox.midX < $1.boundingBox.midX
        }
        let contextPhrase = sorted
          .compactMap { $0.topCandidates(1).first?.string }
          .joined(separator: " ")

        // Tight crop of the target word's bounding box from the (already upright) context image.
        var wordImage: UIImage?
        if let wb = targetWordBox {
          wordImage = Self.cropImage(image: contextImage, visionRect: wb.box)
        }

        #if DEBUG
        NSLog("[WordContext] target word=\"%@\" from %d candidate words", targetWord, allWords.count)
        NSLog("[WordContext] context=\"%@\" (%d lines)", String(contextPhrase.prefix(100)), observations.count)
        if let wb = targetWordBox {
          NSLog("[WordContext]   wordBox=(%.3f,%.3f,%.3f,%.3f) localTip=(%.3f,%.3f)",
                wb.box.minX, wb.box.minY, wb.box.width, wb.box.height, localTipX, localTipY)
        }
        #endif

        continuation.resume(returning: WordInContextResult(
          word: targetWord,
          contextPhrase: contextPhrase,
          wordImage: wordImage,
          contextImage: contextImage
        ))
      }
    }
  }

  // MARK: - OCR

  /// Runs text recognition on a CGImage. Uses the reusable request object.
  private func runOCR(on cgImage: CGImage) -> String {
    let handler = VNImageRequestHandler(cgImage: cgImage)
    try? handler.perform([textRequest])

    guard let observations = textRequest.results, !observations.isEmpty else {
      #if DEBUG
      NSLog("[OCR] no text found in preprocessed crop")
      #endif
      return ""
    }

    #if DEBUG
    NSLog("[OCR] found %d observations", observations.count)
    for obs in observations {
      if let top = obs.topCandidates(1).first {
        NSLog("[OCR]   text=%@ conf=%.2f", top.string, top.confidence)
      }
    }
    #endif

    // Sort observations top-to-bottom, left-to-right
    // Vision y=0 is bottom, so higher midY = higher on screen
    let sorted = observations.sorted {
      if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.02 {
        return $0.boundingBox.midY > $1.boundingBox.midY
      }
      return $0.boundingBox.midX < $1.boundingBox.midX
    }

    return sorted
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: " ")
  }

  // MARK: - Preprocessing

  /// Upscale 2x → document enhance → sharpen.
  /// Returns nil if any step fails.
  private func preprocess(_ image: UIImage) -> CGImage? {
    guard let cgImage = image.cgImage else { return nil }
    var ci = CIImage(cgImage: cgImage)

    // 1. Upscale 2x — sufficient for Vision OCR on small crops (~86x36 → ~172x72)
    ci = ci.applyingFilter("CILanczosScaleTransform", parameters: [
      kCIInputScaleKey: 2.0,
      kCIInputAspectRatioKey: 1.0
    ])

    // 2. Document enhance — designed for text: boosts contrast, removes shadows
    ci = ci.applyingFilter("CIDocumentEnhancer", parameters: [
      "inputAmount": 1.0
    ])

    // 3. Sharpen luminance — crisps up character edges after upscaling
    ci = ci.applyingFilter("CISharpenLuminance", parameters: [
      kCIInputSharpnessKey: 0.6,
      kCIInputRadiusKey: 1.5
    ])

    return ciContext.createCGImage(ci, from: ci.extent)
  }

  // MARK: - Image Cropping

  /// Shared CIContext for the static crop method — avoids ~10ms per-call allocation.
  private static let cropContext = CIContext(options: [.useSoftwareRenderer: false])

  /// Crops a UIImage using a Vision normalized rect (bottom-left origin).
  /// Uses CIImage with orientation baked in — avoids a full-resolution UIGraphicsImageRenderer redraw.
  private static func cropImage(image: UIImage, visionRect: CGRect) -> UIImage? {
    guard let cgImage = image.cgImage else { return nil }

    // Apply EXIF orientation via CIImage so crop coordinates are in display space
    let oriented = CIImage(cgImage: cgImage).oriented(forExifOrientation: Int32(image.imageOrientation.exifValue))

    let extent = oriented.extent  // in display-oriented pixel space

    // Vision (0,0) = bottom-left; CIImage (0,0) = bottom-left — same coordinate system
    let pixelCrop = CGRect(
      x: visionRect.minX * extent.width + extent.origin.x,
      y: visionRect.minY * extent.height + extent.origin.y,
      width: visionRect.width * extent.width,
      height: visionRect.height * extent.height
    )

    #if DEBUG
    NSLog("[OCR] crop rect — vision=(%.3f,%.3f,%.3f,%.3f) pixels=(%.0f,%.0f,%.0f,%.0f)",
          visionRect.origin.x, visionRect.origin.y, visionRect.width, visionRect.height,
          pixelCrop.origin.x, pixelCrop.origin.y, pixelCrop.width, pixelCrop.height)
    #endif

    let cropped = oriented.cropped(to: pixelCrop)

    guard let croppedCG = cropContext.createCGImage(cropped, from: cropped.extent) else { return nil }
    return UIImage(cgImage: croppedCG, scale: image.scale, orientation: .up)
  }
}

// MARK: - UIImage.Orientation → EXIF value

private extension UIImage.Orientation {
  /// Maps UIImage.Orientation to the EXIF orientation integer expected by CIImage.oriented(forExifOrientation:).
  var exifValue: Int {
    switch self {
    case .up:            return 1
    case .down:          return 3
    case .left:          return 8
    case .right:         return 6
    case .upMirrored:    return 2
    case .downMirrored:  return 4
    case .leftMirrored:  return 5
    case .rightMirrored: return 7
    @unknown default:    return 1
    }
  }
}
