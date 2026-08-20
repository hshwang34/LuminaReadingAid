//
// CoverCanonicalizer.swift
//
// Warps a detected four-corner cover quad to an upright canonical image
// using CIPerspectiveCorrection, then downsamples to a fixed target size
// that feeds into OCR + Qwen extraction.
//

import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import CoreGraphics

enum CoverCanonicalizer {

  /// Canonical output size. 512×768 chosen so 24pt title text at ~5% page
  /// height renders at ~38px — comfortably above Vision's accurate-level floor.
  static let defaultTargetSize = CGSize(width: 512, height: 768)

  private static let ciContext = CIContext(options: [
    .useSoftwareRenderer: false,
    .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
    .outputColorSpace: CGColorSpaceCreateDeviceRGB(),
  ])

  /// Warps the four-corner quad on `pixelBuffer` to an upright canonical image.
  /// `quad` corners are in Vision normalized coords (0..1, y-up) — the same
  /// coordinate system `PageTrackingService.detectDocument` produces.
  static func canonicalize(pixelBuffer: CVPixelBuffer,
                           quad: PageTrackingService.DocumentQuad,
                           targetSize: CGSize = defaultTargetSize) -> CGImage? {
    let baseImage = CIImage(cvPixelBuffer: pixelBuffer)
    let extent = baseImage.extent
    let W = extent.width
    let H = extent.height
    let ox = extent.origin.x
    let oy = extent.origin.y

    // Vision y-up and CIImage y-up match — no flip needed.
    let tl = CGPoint(x: quad.topLeft.x * W + ox,     y: quad.topLeft.y * H + oy)
    let tr = CGPoint(x: quad.topRight.x * W + ox,    y: quad.topRight.y * H + oy)
    let br = CGPoint(x: quad.bottomRight.x * W + ox, y: quad.bottomRight.y * H + oy)
    let bl = CGPoint(x: quad.bottomLeft.x * W + ox,  y: quad.bottomLeft.y * H + oy)

    let filter = CIFilter.perspectiveCorrection()
    filter.inputImage = baseImage
    filter.topLeft = tl
    filter.topRight = tr
    filter.bottomRight = br
    filter.bottomLeft = bl
    filter.crop = true

    guard let warped = filter.outputImage else { return nil }

    // Fit-to-height scale: covers are taller than wide so height drives size.
    let warpedExtent = warped.extent
    guard warpedExtent.height > 0 else { return nil }
    let scale = targetSize.height / warpedExtent.height
    let scaled = warped.applyingFilter("CILanczosScaleTransform", parameters: [
      kCIInputScaleKey: scale,
      kCIInputAspectRatioKey: 1.0
    ])

    return ciContext.createCGImage(scaled, from: scaled.extent)
  }
}
