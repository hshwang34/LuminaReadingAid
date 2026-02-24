//
// WordCaptureService.swift
//
// Runs VNRecognizeTextRequest on the camera frame region above the index fingertip
// and returns the recognized word closest to the tip's horizontal position.
//

import Vision
import UIKit

final class WordCaptureService {

  // MARK: - Crop Parameters

  /// How far above the tip (in Vision normalized Y) to start the OCR region
  private let verticalOffset: CGFloat = 0.03
  /// Width of the OCR crop region (fraction of frame width, centered on tip X)
  private let cropWidth: CGFloat = 0.15
  /// Height of the OCR crop region (fraction of frame height)
  private let cropHeight: CGFloat = 0.06

  // MARK: - Public API

  /// Recognizes the word above `tipNormalized` in `image`.
  ///
  /// - Parameters:
  ///   - image: The full video frame as UIImage.
  ///   - tipNormalized: Index tip position in Vision normalized coords (0–1, bottom-left origin).
  /// - Returns: The recognized word, or nil if OCR finds nothing.
  func recognizeWord(in image: UIImage, tipNormalized: CGPoint) async -> String? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async { [self] in
        guard let cgImage = image.cgImage else {
          continuation.resume(returning: nil)
          return
        }

        var recognized: String? = nil

        let request = VNRecognizeTextRequest { req, _ in
          guard let observations = req.results as? [VNRecognizedTextObservation],
                !observations.isEmpty
          else {
            NSLog("[OCR] no observations found in full frame")
            return
          }

          NSLog("[OCR] found %d observations", observations.count)
          for obs in observations {
            NSLog("[OCR]   bbox=(%.2f,%.2f,%.2f,%.2f) text=%@",
                  obs.boundingBox.origin.x, obs.boundingBox.origin.y,
                  obs.boundingBox.width, obs.boundingBox.height,
                  obs.topCandidates(1).first?.string ?? "?")
          }

          // Pick the observation closest to tip position
          let tipX = tipNormalized.x
          let tipY = tipNormalized.y
          let best = observations.min(by: {
            let d0 = hypot($0.boundingBox.midX - tipX, $0.boundingBox.midY - tipY)
            let d1 = hypot($1.boundingBox.midX - tipX, $1.boundingBox.midY - tipY)
            return d0 < d1
          })

          let raw = best?.topCandidates(1).first?.string ?? ""
          recognized = raw
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .first
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        // No regionOfInterest — scan full frame to diagnose

        // perform() is synchronous; completion handler fires before it returns
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        continuation.resume(returning: recognized)
      }
    }
  }
}
