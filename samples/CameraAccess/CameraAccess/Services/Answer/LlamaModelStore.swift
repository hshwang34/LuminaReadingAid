//
// LlamaModelStore.swift
//
// Owns the GGUF file on disk: where it lives, downloading it once, and resuming that
// download when it is interrupted.
//
// The model is ~1.1 GB, which is the single largest thing this app ever asks of a
// user. Two consequences shape this file:
//
//  - The download MUST resume. A student on campus wifi will lose the connection
//    partway through, and restarting a gigabyte from zero is how an app gets deleted.
//    Resume is done with a Range request against the partial file rather than
//    URLSession resume data, because resume data does not survive app termination.
//
//  - The file goes in Application Support, not Caches. iOS purges Caches under disk
//    pressure, and silently losing the model would strand the reader mid-session with
//    a gigabyte to re-download. It is excluded from iCloud backup, since it is
//    re-downloadable and would otherwise bloat every backup.
//

import Foundation

actor LlamaModelStore {

  static let shared = LlamaModelStore()

  /// Qwen3 1.7B, 4-bit K-quant. Chosen for Korean strength at this size and for
  /// fitting comfortably on an A16 alongside the audio pipeline.
  ///
  /// Sourced from unsloth rather than the official Qwen GGUF repo: Qwen publishes only
  /// a Q8_0 build (~1.8 GB), which is both larger than an iPhone should carry and
  /// slower to decode than the quality difference justifies at this size.
  static let modelFileName = "Qwen3-1.7B-Q4_K_M.gguf"
  static let modelURL = URL(
    string: "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf"
  )!
  /// Used only to render a size estimate before the first byte arrives.
  static let approximateBytes: Int64 = 1_120_000_000

  enum StoreError: LocalizedError {
    case badResponse(Int)
    case incomplete
    case noSpace

    var errorDescription: String? {
      switch self {
      case .badResponse(let code):
        // Include the URL: a 404 here means the model file moved or was renamed
        // upstream, which is a build-time fix, not something a user can retry past.
        "The model download failed (HTTP \(code)) from \(LlamaModelStore.modelURL.absoluteString)"
      case .incomplete: "The model download ended early."
      case .noSpace: "Not enough free space to download the language model."
      }
    }
  }

  // MARK: - Locations

  nonisolated var modelFileURL: URL {
    Self.applicationSupport.appendingPathComponent(Self.modelFileName)
  }

  private var partialFileURL: URL {
    modelFileURL.appendingPathExtension("partial")
  }

  private nonisolated static var applicationSupport: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("Models", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  nonisolated var isModelPresent: Bool {
    FileManager.default.fileExists(atPath: modelFileURL.path)
  }

  // MARK: - Acquisition

  /// Returns the local model path, downloading it first if necessary.
  /// Progress is reported as 0...1 while downloading.
  func ensureModel(onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    if isModelPresent { return modelFileURL }
    try await download(onProgress: onProgress)
    return modelFileURL
  }

  private func download(onProgress: @escaping @Sendable (Double) -> Void) async throws {
    let fm = FileManager.default
    var existingBytes: Int64 = 0
    if let attrs = try? fm.attributesOfItem(atPath: partialFileURL.path),
       let size = attrs[.size] as? Int64 {
      existingBytes = size
    }

    var request = URLRequest(url: Self.modelURL)
    request.timeoutInterval = 60
    if existingBytes > 0 {
      // Resume exactly where the last attempt stopped.
      request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
    }

    // Deliberately NOT URLSession.bytes(for:). That yields one UInt8 at a time
    // through async-sequence machinery, which for a ~1.1 GB file means over a billion
    // iterations and makes the download CPU-bound rather than network-bound. A
    // delegate-driven data task hands over real multi-kilobyte chunks instead.
    let downloader = ChunkedDownloader(
      destination: partialFileURL,
      alreadyOnDisk: existingBytes,
      fallbackTotal: Self.approximateBytes,
      onProgress: onProgress
    )

    let written = try await downloader.run(request)
    guard written > 0 else { throw StoreError.incomplete }

    try? fm.removeItem(at: modelFileURL)
    try fm.moveItem(at: partialFileURL, to: modelFileURL)
    excludeFromBackup(modelFileURL)
    onProgress(1.0)
  }

  private func excludeFromBackup(_ url: URL) {
    var url = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
  }

  // MARK: - Maintenance

  /// Removes the model and any partial download. Exposed for the debug menu and for
  /// a future "free up space" affordance.
  func deleteModel() {
    try? FileManager.default.removeItem(at: modelFileURL)
    try? FileManager.default.removeItem(at: partialFileURL)
  }
}

// MARK: - Chunked downloader

/// Streams an HTTP body to disk in whatever chunks the network delivers, appending to
/// a partial file so an interrupted download resumes rather than restarts.
///
/// Written against the URLSession delegate API rather than the async convenience
/// methods because those either give no progress (`download(for:)`) or iterate byte by
/// byte (`bytes(for:)`), and neither is usable for a file this size.
private final class ChunkedDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {

  private let destination: URL
  private let alreadyOnDisk: Int64
  private let fallbackTotal: Int64
  private let onProgress: @Sendable (Double) -> Void

  private var handle: FileHandle?
  private var written: Int64 = 0
  private var expectedTotal: Int64 = 0
  private var lastReport = Date.distantPast
  private var continuation: CheckedContinuation<Int64, Error>?
  private var session: URLSession?

  init(
    destination: URL,
    alreadyOnDisk: Int64,
    fallbackTotal: Int64,
    onProgress: @escaping @Sendable (Double) -> Void
  ) {
    self.destination = destination
    self.alreadyOnDisk = alreadyOnDisk
    self.fallbackTotal = fallbackTotal
    self.onProgress = onProgress
    self.written = alreadyOnDisk
  }

  func run(_ request: URLRequest) async throws -> Int64 {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation

      let queue = OperationQueue()
      queue.maxConcurrentOperationCount = 1  // serialises file writes
      let session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
      self.session = session
      session.dataTask(with: request).resume()
    }
  }

  private func finish(_ result: Result<Int64, Error>) {
    try? handle?.close()
    handle = nil
    session?.finishTasksAndInvalidate()
    session = nil

    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(with: result)
  }

  // MARK: URLSessionDataDelegate

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      finish(.failure(LlamaModelStore.StoreError.badResponse(-1)))
      return
    }

    // 206 = the server honoured our Range request. 200 = it ignored it and is sending
    // the whole file, which makes anything already on disk meaningless.
    var startingPoint = alreadyOnDisk
    if alreadyOnDisk > 0 && http.statusCode == 200 {
      try? FileManager.default.removeItem(at: destination)
      startingPoint = 0
    }

    guard http.statusCode == 200 || http.statusCode == 206 else {
      completionHandler(.cancel)
      finish(.failure(LlamaModelStore.StoreError.badResponse(http.statusCode)))
      return
    }

    let remaining = http.expectedContentLength > 0 ? http.expectedContentLength : fallbackTotal
    expectedTotal = startingPoint + remaining
    written = startingPoint

    let fm = FileManager.default
    if !fm.fileExists(atPath: destination.path) {
      fm.createFile(atPath: destination.path, contents: nil)
    }
    do {
      let handle = try FileHandle(forWritingTo: destination)
      if startingPoint > 0 {
        try handle.seekToEnd()
      } else {
        try handle.truncate(atOffset: 0)
      }
      self.handle = handle
    } catch {
      completionHandler(.cancel)
      finish(.failure(error))
      return
    }

    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    do {
      try handle?.write(contentsOf: data)
      written += Int64(data.count)
    } catch {
      dataTask.cancel()
      finish(.failure(error))
      return
    }

    // Progress drives a SwiftUI view; a gigabyte of updates would cost more than the
    // transfer itself.
    if Date().timeIntervalSince(lastReport) > 0.2 {
      lastReport = Date()
      onProgress(min(1.0, Double(written) / Double(max(expectedTotal, 1))))
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error {
      // A partial file is kept on purpose — that's what makes the next attempt resume.
      finish(.failure(error))
    } else {
      finish(.success(written))
    }
  }
}
