//
// HEVCDecoder.swift
//
// Hardware-accelerated HEVC (H.265) decoder using VTDecompressionSession.
// Decodes compressed CMSampleBuffers from the DAT SDK into CVPixelBuffers
// for Vision processing and UIImage display.
//

import CoreMedia
import CoreImage
import VideoToolbox
import UIKit

final class HEVCDecoder {

  /// Result of decoding a single HEVC frame.
  struct DecodedFrame {
    /// Decoded pixel buffer — feed directly to VNImageRequestHandler for Vision.
    let pixelBuffer: CVPixelBuffer
  }

  /// Serial queue for all decode operations. Exposed so callers can dispatch onto it.
  let decoderQueue = DispatchQueue(label: "com.Lumina.ReadingAid.hevc-decoder", qos: .userInitiated)

  // MARK: - Private State (accessed only on decoderQueue)

  private var decompressionSession: VTDecompressionSession?
  private var currentFormatDescription: CMFormatDescription?

  /// Reused CIContext — creating one per frame costs ~10ms.
  /// Color management disabled since output is for display + Vision, not color-critical.
  private let ciContext = CIContext(options: [
    .useSoftwareRenderer: false,
    .workingColorSpace: NSNull(),
  ])

  // MARK: - Pixel Buffer Attributes

  private static let pixelBufferAttributes: CFDictionary = [
    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
  ] as CFDictionary

  // MARK: - Public API

  /// Decodes a compressed HEVC CMSampleBuffer into a CVPixelBuffer + UIImage.
  /// **Must be called on `decoderQueue`.**
  /// Returns nil if decoding fails or the session cannot be created.
  func decode(_ sampleBuffer: CMSampleBuffer) -> DecodedFrame? {
    dispatchPrecondition(condition: .onQueue(decoderQueue))

    // Ensure we have a valid session for this frame's format
    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
      #if DEBUG
      NSLog("[HEVCDecoder] no format description in sample buffer")
      #endif
      return nil
    }

    if !ensureSession(for: formatDesc) {
      return nil
    }

    guard let session = decompressionSession else { return nil }

    // Synchronous decode — blocks until the hardware decoder returns the pixel buffer
    var outputPixelBuffer: CVPixelBuffer?
    var infoFlags = VTDecodeInfoFlags()

    let status = VTDecompressionSessionDecodeFrame(
      session,
      sampleBuffer: sampleBuffer,
      flags: [._1xRealTimePlayback],
      infoFlagsOut: &infoFlags,
      outputHandler: { decodeStatus, _, imageBuffer, _, _ in
        guard decodeStatus == noErr else {
          #if DEBUG
          NSLog("[HEVCDecoder] decode callback error: %d", decodeStatus)
          #endif
          return
        }
        outputPixelBuffer = imageBuffer
      }
    )

    guard status == noErr else {
      #if DEBUG
      NSLog("[HEVCDecoder] VTDecompressionSessionDecodeFrame failed: %d", status)
      #endif
      // Session may be invalid — tear down so it recreates on next frame
      if status == kVTInvalidSessionErr {
        tearDownSession()
      }
      return nil
    }

    guard let pixelBuffer = outputPixelBuffer else { return nil }

    return DecodedFrame(pixelBuffer: pixelBuffer)
  }

  /// Converts a CVPixelBuffer to UIImage. Thread-safe — can be called from any thread.
  /// Uses the reused CIContext for efficient rendering.
  func makeImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }

  /// Tears down the decompression session. Call when streaming stops or app backgrounds.
  /// Thread-safe — dispatches synchronously to `decoderQueue`.
  func invalidate() {
    decoderQueue.sync { [self] in
      tearDownSession()
    }
  }

  // MARK: - Session Management

  /// Ensures a valid VTDecompressionSession exists for the given format description.
  /// Returns true if a session is ready, false if creation failed.
  private func ensureSession(for formatDesc: CMFormatDescription) -> Bool {
    // Check if existing session can handle this format
    if let session = decompressionSession {
      if let current = currentFormatDescription,
         CMFormatDescriptionEqual(current, otherFormatDescription: formatDesc) {
        return true  // Same format, session is fine
      }
      // Format changed — can the session adapt?
      if VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: formatDesc) {
        currentFormatDescription = formatDesc
        return true
      }
      // Must recreate
      tearDownSession()
    }

    // Create new session
    return createSession(formatDescription: formatDesc)
  }

  private func createSession(formatDescription: CMFormatDescription) -> Bool {
    var session: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      formatDescription: formatDescription,
      decoderSpecification: nil,
      imageBufferAttributes: Self.pixelBufferAttributes,
      outputCallback: nil,  // using block-based decode API
      decompressionSessionOut: &session
    )

    guard status == noErr, let session else {
      #if DEBUG
      NSLog("[HEVCDecoder] VTDecompressionSessionCreate failed: %d", status)
      #endif
      return false
    }

    decompressionSession = session
    currentFormatDescription = formatDescription
    #if DEBUG
    let dims = CMVideoFormatDescriptionGetDimensions(formatDescription)
    NSLog("[HEVCDecoder] session created — %dx%d", dims.width, dims.height)
    #endif
    return true
  }

  private func tearDownSession() {
    if let session = decompressionSession {
      VTDecompressionSessionWaitForAsynchronousFrames(session)
      VTDecompressionSessionInvalidate(session)
    }
    decompressionSession = nil
    currentFormatDescription = nil
  }
}
