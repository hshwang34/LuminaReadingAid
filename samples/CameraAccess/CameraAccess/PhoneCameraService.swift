//
// PhoneCameraService.swift
//
// Wraps AVCaptureSession to provide a phone-camera frame source that mirrors
// the DAT SDK glasses pipeline: 720p, 15 fps, CVPixelBuffer output.
//

import AVFoundation
import UIKit

final class PhoneCameraService: NSObject, @unchecked Sendable {
  var onFrame: ((CVPixelBuffer) -> Void)?
  var onPhoto: ((Data) -> Void)?
  var onError: ((String) -> Void)?

  private let captureSession = AVCaptureSession()
  private let outputQueue = DispatchQueue(label: "com.Lumina.ReadingAid.phonecamera", qos: .userInitiated)
  private var latestPixelBuffer: CVPixelBuffer?
  private let bufferLock = NSLock()
  /// Guards against re-adding inputs/outputs on repeated `start()` calls.
  /// AVCaptureSession throws `NSInvalidArgumentException` if you try to add a
  /// second video input while one is already attached.
  private var isConfigured = false

  func start() async {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized:
      break
    case .notDetermined:
      let granted = await AVCaptureDevice.requestAccess(for: .video)
      guard granted else {
        onError?("Camera access denied.")
        return
      }
    default:
      onError?("Camera access denied. Please grant permission in Settings.")
      return
}

    if !isConfigured {
      configureCaptureSession()
      isConfigured = true
    }
    if !captureSession.isRunning {
      captureSession.startRunning()
    }
  }

  func stop() {
    if captureSession.isRunning {
      captureSession.stopRunning()
    }
  }

  func capturePhoto() {
    bufferLock.lock()
    let buffer = latestPixelBuffer
    bufferLock.unlock()

    guard let buffer else { return }

    outputQueue.async { [weak self] in
      let ciImage = CIImage(cvPixelBuffer: buffer)
      let context = CIContext()
      guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
      let uiImage = UIImage(cgImage: cgImage)
      guard let jpegData = uiImage.jpegData(compressionQuality: 0.9) else { return }
      self?.onPhoto?(jpegData)
    }
  }

  private func configureCaptureSession() {
    captureSession.beginConfiguration()
    captureSession.sessionPreset = .hd1280x720

    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
          let input = try? AVCaptureDeviceInput(device: camera) else {
      onError?("Failed to access rear camera.")
      captureSession.commitConfiguration()
      return
    }

    if captureSession.canAddInput(input) {
      captureSession.addInput(input)
    }

    // Configure 30 fps — higher frame rate means smaller inter-frame displacement,
    // which improves VNTrackObjectRequest reliability during fast camera motion.
    do {
      try camera.lockForConfiguration()
      camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
      camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
      camera.unlockForConfiguration()
    } catch {
      // Non-fatal — will just run at default frame rate
    }

    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ]
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: outputQueue)

    if captureSession.canAddOutput(output) {
      captureSession.addOutput(output)
    }

    // Set landscape orientation to match glasses frame orientation
    if let connection = output.connection(with: .video) {
      if connection.isVideoRotationAngleSupported(90) {
        connection.videoRotationAngle = 90
      }
    }

    captureSession.commitConfiguration()
  }
}

extension PhoneCameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    bufferLock.lock()
    latestPixelBuffer = pixelBuffer
    bufferLock.unlock()

    onFrame?(pixelBuffer)
  }
}
