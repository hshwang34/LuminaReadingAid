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

final class WordCaptureService {

  private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

  // MARK: - Public API

  /// Crops `cropRect` from `image`, preprocesses the crop, then runs OCR on it.
  /// Returns all recognized text and the preprocessed thumbnail.
  func recognizeWord(in image: UIImage, cropRect: CGRect) async -> WordCaptureResult {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async { [ciContext] in

        // Step 1: Crop the oriented region
        guard let originalCrop = Self.cropImage(image: image, visionRect: cropRect) else {
          NSLog("[OCR] crop failed")
          continuation.resume(returning: WordCaptureResult(text: "", originalCrop: nil, preprocessedCrop: nil))
          return
        }
        NSLog("[OCR] original crop size: %.0fx%.0f", originalCrop.size.width, originalCrop.size.height)

        // Step 2: Preprocess — upscale 4x, document enhance, sharpen
        guard let preprocessedCG = Self.preprocess(originalCrop, context: ciContext) else {
          NSLog("[OCR] preprocessing failed, using raw crop for OCR")
          continuation.resume(returning: WordCaptureResult(text: "", originalCrop: originalCrop, preprocessedCrop: nil))
          return
        }
        let preprocessedCrop = UIImage(cgImage: preprocessedCG)
        NSLog("[OCR] preprocessed size: %.0fx%.0f", preprocessedCrop.size.width, preprocessedCrop.size.height)

        // Step 3: Run OCR on the preprocessed crop
        // No regionOfInterest — the entire image IS the crop region
        var recognizedText = ""

        let request = VNRecognizeTextRequest { req, _ in
          guard let observations = req.results as? [VNRecognizedTextObservation],
                !observations.isEmpty
          else {
            NSLog("[OCR] no text found in preprocessed crop")
            return
          }

          NSLog("[OCR] found %d observations", observations.count)
          for obs in observations {
            NSLog("[OCR]   text=%@ conf=%.2f",
                  obs.topCandidates(1).first?.string ?? "?",
                  obs.topCandidates(1).first?.confidence ?? 0)
          }

          // Sort observations top-to-bottom, left-to-right
          // Vision y=0 is bottom, so higher midY = higher on screen
          let sorted = observations.sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.02 {
              return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.midX < $1.boundingBox.midX
          }

          recognizedText = sorted
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cgImage: preprocessedCG, options: [:])
        try? handler.perform([request])

        NSLog("[OCR] final text: \"%@\"", recognizedText)
        continuation.resume(returning: WordCaptureResult(
          text: recognizedText,
          originalCrop: originalCrop,
          preprocessedCrop: preprocessedCrop
        ))
      }
    }
  }

  // MARK: - Preprocessing

  /// Upscale 4x → document enhance → sharpen.
  /// Returns nil if any step fails.
  private static func preprocess(_ image: UIImage, context: CIContext) -> CGImage? {
    guard let cgImage = image.cgImage else { return nil }
    var ci = CIImage(cgImage: cgImage)

    // 1. Upscale 4x — biggest single improvement for small text
    ci = ci.applyingFilter("CILanczosScaleTransform", parameters: [
      kCIInputScaleKey: 4.0,
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

    return context.createCGImage(ci, from: ci.extent)
  }

  // MARK: - Image Cropping

  /// Crops a UIImage using a Vision normalized rect (bottom-left origin).
  /// Renders into an orientation-normalized buffer first so EXIF rotation
  /// is baked in before cropping.
  private static func cropImage(image: UIImage, visionRect: CGRect) -> UIImage? {
    let displaySize = image.size
    let renderer = UIGraphicsImageRenderer(size: displaySize)
    let oriented = renderer.image { _ in image.draw(at: .zero) }

    guard let cgImage = oriented.cgImage else { return nil }
    let width = CGFloat(cgImage.width)
    let height = CGFloat(cgImage.height)

    // Vision (0,0) = bottom-left; CGImage (0,0) = top-left — flip Y
    let cgCropRect = CGRect(
      x: visionRect.minX * width,
      y: (1.0 - visionRect.maxY) * height,
      width: visionRect.width * width,
      height: visionRect.height * height
    )
    NSLog("[OCR] crop rect — vision=(%.3f,%.3f,%.3f,%.3f) pixels=(%.0f,%.0f,%.0f,%.0f)",
          visionRect.origin.x, visionRect.origin.y, visionRect.width, visionRect.height,
          cgCropRect.origin.x, cgCropRect.origin.y, cgCropRect.width, cgCropRect.height)

    guard let cropped = cgImage.cropping(to: cgCropRect) else { return nil }
    return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
  }
}
