//
// PassageExtractionService.swift
//
// Extracts text from pre-cropped, upright strip images of a highlighted region.
// Callers extract oriented crops from the captured photo (see OrientedCrop.extractUpright)
// so by the time the service sees them, each strip is an axis-aligned upright UIImage
// containing horizontal text ready for OCR.
//
// Pipeline: for each strip → preprocess → OCR → concatenate. Runs once per highlight
// gesture completion (not per-frame).
//

import Vision
import CoreImage
import CoreGraphics
import UIKit

// MARK: - Result

struct PassageExtractionResult {
  let text: String
  let croppedRegionImage: UIImage?
}

// MARK: - Service

final class PassageExtractionService {
  /// GPU-backed CIContext — reusable, thread-safe.
  private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

  /// Reusable OCR request.
  private let textRequest: VNRecognizeTextRequest = {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    req.recognitionLanguages = ["en-US"]
    return req
  }()

  // MARK: - Public API

  /// Extracts text from pre-cropped, upright strip images in reading order.
  ///
  /// - Parameter strips: Upright UIImages (one per strip), already rotated so text is horizontal.
  ///                     Produced by `OrientedCrop.extractUpright(from:)`.
  /// - Returns: Concatenated text and a vertically-stacked composite of the strips.
  func extractPassage(strips: [UIImage]) async -> PassageExtractionResult {
    guard !strips.isEmpty else {
      return PassageExtractionResult(text: "", croppedRegionImage: nil)
    }

    var lineTexts: [String] = []
    var ocrImages: [CGImage] = []

    for strip in strips {
      guard let stripCG = strip.cgImage else { continue }
      let ci = CIImage(cgImage: stripCG)
      let preprocessed = preprocess(ci)
      guard let ocrImage = ciContext.createCGImage(preprocessed, from: preprocessed.extent) else {
        continue
      }
      ocrImages.append(ocrImage)

      #if DEBUG
      NSLog("[PassageExtraction] strip pixels=%dx%d", stripCG.width, stripCG.height)
      #endif

      let text = recognizeText(in: ocrImage)
      if !text.isEmpty {
        lineTexts.append(text)
      }
    }

    let combinedText = lineTexts.joined(separator: " ")
    let compositeImage = createCompositeImage(from: ocrImages)

    #if DEBUG
    NSLog("[PassageExtraction] extracted %d characters from %d strips: \"%@\"",
          combinedText.count, strips.count, String(combinedText.prefix(100)))
    #endif

    return PassageExtractionResult(text: combinedText, croppedRegionImage: compositeImage)
  }

  // MARK: - Preprocessing

  /// Upscale 2x → document enhance → sharpen.
  private func preprocess(_ ci: CIImage) -> CIImage {
    var result = ci

    result = result.applyingFilter("CILanczosScaleTransform", parameters: [
      kCIInputScaleKey: 2.0,
      kCIInputAspectRatioKey: 1.0
    ])

    result = result.applyingFilter("CIDocumentEnhancer", parameters: [
      "inputAmount": 1.0
    ])

    result = result.applyingFilter("CISharpenLuminance", parameters: [
      kCIInputSharpnessKey: 0.6,
      kCIInputRadiusKey: 1.5
    ])

    return result
  }

  // MARK: - OCR

  private func recognizeText(in cgImage: CGImage) -> String {
    let handler = VNImageRequestHandler(cgImage: cgImage)
    do {
      try handler.perform([textRequest])
    } catch {
      NSLog("[PassageExtraction] OCR error: %@", error.localizedDescription)
      return ""
    }

    guard let observations = textRequest.results, !observations.isEmpty else {
      return ""
    }

    // Sort top-to-bottom (higher Vision Y = higher on page = first in reading order)
    let sorted = observations.sorted { a, b in
      let aMidY = a.boundingBox.midY
      let bMidY = b.boundingBox.midY
      if abs(aMidY - bMidY) < 0.02 {
        return a.boundingBox.midX < b.boundingBox.midX
      }
      return aMidY > bMidY
    }

    return sorted.compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: " ")
  }

  // MARK: - Composite Image

  /// Vertically stacks cropped line strips into a single image.
  private func createCompositeImage(from images: [CGImage]) -> UIImage? {
    guard !images.isEmpty else { return nil }
    if images.count == 1 { return UIImage(cgImage: images[0]) }

    let totalHeight = images.reduce(0) { $0 + $1.height }
    let maxWidth = images.map(\.width).max() ?? 0
    guard maxWidth > 0, totalHeight > 0 else { return nil }

    UIGraphicsBeginImageContext(CGSize(width: maxWidth, height: totalHeight))
    defer { UIGraphicsEndImageContext() }

    var yOffset: CGFloat = 0
    for cgImage in images {
      let img = UIImage(cgImage: cgImage)
      img.draw(at: CGPoint(x: 0, y: yOffset))
      yOffset += CGFloat(cgImage.height)
    }

    return UIGraphicsGetImageFromCurrentImageContext()
  }
}
