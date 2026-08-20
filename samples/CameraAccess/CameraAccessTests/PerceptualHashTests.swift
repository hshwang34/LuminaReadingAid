//
// PerceptualHashTests.swift
//
// Unit tests for the 64-bit average-hash implementation. Confirms:
//   - Hashes are deterministic for a given image.
//   - Hamming distance behaves sensibly for identical, similar, and different
//     images.
//   - Hex parsing edge cases (length mismatch, bad chars) return the max
//     distance so downstream thresholding rejects them.
//

import XCTest
import CoreGraphics
@testable import CameraAccess

final class PerceptualHashTests: XCTestCase {

  // MARK: - Helpers

  /// Build a small CGImage filled with a constant grayscale value.
  private func solidImage(size: Int = 16, value: UInt8) -> CGImage {
    let bytes = [UInt8](repeating: value, count: size * size)
    let colorSpace = CGColorSpaceCreateDeviceGray()
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
      width: size,
      height: size,
      bitsPerComponent: 8,
      bitsPerPixel: 8,
      bytesPerRow: size,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )!
  }

  /// Build a 16×16 grayscale image with a simple gradient so the aHash has
  /// real structure (not all bits the same).
  private func gradientImage(size: Int = 16, reversed: Bool = false) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: size * size)
    for y in 0..<size {
      for x in 0..<size {
        let value = reversed ? UInt8(255 - (x * 255 / (size - 1)))
                              : UInt8(x * 255 / (size - 1))
        bytes[y * size + x] = value
      }
    }
    let colorSpace = CGColorSpaceCreateDeviceGray()
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
      width: size,
      height: size,
      bitsPerComponent: 8,
      bitsPerPixel: 8,
      bytesPerRow: size,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )!
  }

  // MARK: - hash()

  func testHashReturnsSixteenHexChars() {
    let image = gradientImage()
    let hash = PerceptualHash.hash(cgImage: image)
    XCTAssertNotNil(hash)
    XCTAssertEqual(hash?.count, 16)
    XCTAssertTrue(hash?.allSatisfy { $0.isHexDigit } ?? false)
  }

  func testHashIsDeterministic() {
    let image = gradientImage()
    let hash1 = PerceptualHash.hash(cgImage: image)
    let hash2 = PerceptualHash.hash(cgImage: image)
    XCTAssertEqual(hash1, hash2)
  }

  func testIdenticalImagesHaveZeroHammingDistance() {
    let image = gradientImage()
    let h1 = PerceptualHash.hash(cgImage: image)!
    let h2 = PerceptualHash.hash(cgImage: image)!
    XCTAssertEqual(PerceptualHash.hammingDistance(h1, h2), 0)
  }

  func testVeryDifferentImagesHaveLargeHammingDistance() {
    // A left-to-right gradient vs a right-to-left gradient should have a
    // very different average-hash — half of the pixels flip sides of the mean.
    let h1 = PerceptualHash.hash(cgImage: gradientImage(reversed: false))!
    let h2 = PerceptualHash.hash(cgImage: gradientImage(reversed: true))!
    XCTAssertGreaterThanOrEqual(
      PerceptualHash.hammingDistance(h1, h2),
      16,
      "Reversed gradient should differ in at least a quarter of bits"
    )
  }

  // MARK: - hammingDistance()

  func testHammingDistanceAllBitsSet() {
    // 0x0...0 vs 0xf...f → all 64 bits differ.
    XCTAssertEqual(
      PerceptualHash.hammingDistance("0000000000000000", "ffffffffffffffff"),
      64
    )
  }

  func testHammingDistanceIdentical() {
    XCTAssertEqual(
      PerceptualHash.hammingDistance("deadbeefcafef00d", "deadbeefcafef00d"),
      0
    )
  }

  func testHammingDistanceOneBit() {
    // 0x0 and 0x1 differ in exactly one bit.
    XCTAssertEqual(
      PerceptualHash.hammingDistance("0000000000000000", "0000000000000001"),
      1
    )
  }

  func testHammingDistanceMismatchedLengthReturnsMax() {
    XCTAssertEqual(
      PerceptualHash.hammingDistance("deadbeef", "deadbeefcafef00d"),
      64
    )
  }

  func testHammingDistanceBadCharactersReturnsMax() {
    XCTAssertEqual(
      PerceptualHash.hammingDistance("zzzzzzzzzzzzzzzz", "0000000000000000"),
      64
    )
  }
}
