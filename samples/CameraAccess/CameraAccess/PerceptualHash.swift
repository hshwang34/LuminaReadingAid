//
// PerceptualHash.swift
//
// 64-bit average perceptual hash (aHash) for book-cover similarity matching.
// Used by BookIdentificationService's recovery tier: when OCR + Open Library
// can't identify a cover, the pipeline checks whether the canonical cover
// image matches any known-good cover in the library within a Hamming-10
// distance, and recovers the session if it does.
//
// The algorithm is deliberately trivial: downscale to 8×8 grayscale, compute
// the mean, threshold each pixel. No Core Image or Accelerate dependency —
// a plain bitmap CGContext is faster for 64 pixels and keeps the file small
// enough to unit-test without pulling in the rest of the app.
//
// aHash is the right choice for cover matching specifically: book covers have
// large contrasty regions (title blocks, background panels) that survive the
// drastic downsample, and the mean-threshold step gives enough slack to
// tolerate glare, white-balance, and minor crop variation without producing
// false positives between genuinely different covers.
//

import CoreGraphics
import Foundation

enum PerceptualHash {

  /// Compute a 64-bit average-hash of `cgImage`.
  ///
  /// Returns a 16-character lowercase hex string (big-endian — pixel (0,0) is
  /// the high bit) so hashes are directly comparable with substring operations
  /// if needed. Returns nil only if the Core Graphics context can't be created,
  /// which indicates a corrupt image or out-of-memory.
  static func hash(cgImage: CGImage) -> String? {
    let size = 8
    let bytesPerRow = size  // 1 byte per pixel in gray8
    var buffer = [UInt8](repeating: 0, count: size * size)
    let colorSpace = CGColorSpaceCreateDeviceGray()
    let bitmapInfo = CGImageAlphaInfo.none.rawValue

    guard let context = buffer.withUnsafeMutableBytes({ ptr -> CGContext? in
      CGContext(
        data: ptr.baseAddress,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo
      )
    }) else {
      return nil
    }

    // Draw the source into the tiny grayscale context. CG does high-quality
    // downsampling for us; for 64 pixels the overhead is negligible.
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

    // Pull the 64 grayscale bytes back out of our owned buffer. CGContext was
    // drawing into `buffer` directly via the pointer above, so the values are
    // already updated.
    let sum = buffer.reduce(0) { $0 + Int($1) }
    let mean = sum / buffer.count

    // Pack 64 bits MSB-first. Pixel (0,0) is bit 63, pixel (7,7) is bit 0.
    var bits: UInt64 = 0
    for (index, byte) in buffer.enumerated() {
      if Int(byte) > mean {
        bits |= (UInt64(1) << (63 - index))
      }
    }
    return String(format: "%016llx", bits)
  }

  /// Hamming distance between two 16-char hex hashes, returned as an integer
  /// in `0...64`. Returns 64 (maximum possible distance) if either input is
  /// malformed or the wrong length — that's a safe default because a caller
  /// comparing against a threshold will always reject it.
  static func hammingDistance(_ a: String, _ b: String) -> Int {
    guard a.count == 16, b.count == 16 else { return 64 }
    guard let bitsA = UInt64(a, radix: 16), let bitsB = UInt64(b, radix: 16) else {
      return 64
    }
    return (bitsA ^ bitsB).nonzeroBitCount
  }
}
