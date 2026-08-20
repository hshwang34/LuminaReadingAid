/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamView.swift
//
// Main UI for video streaming from Meta wearable devices using the DAT SDK.
// This view demonstrates the complete streaming API: video streaming with real-time display, photo capture,
// and error handling.
//

import MWDATCore
import SwiftData
import SwiftUI

struct StreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var wearablesVM: WearablesViewModel

  var body: some View {
    ZStack {
      // Black background for letterboxing/pillarboxing
      Color.black
        .edgesIgnoringSafeArea(.all)

      // Video backdrop
      if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          ZStack {
            Image(uiImage: videoFrame)
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(width: geometry.size.width, height: geometry.size.height)
              .clipped()

            if viewModel.isHandTrackingEnabled {
              HandOverlayView(
                trackingResult: viewModel.handTrackingResult,
                imageSize: viewModel.videoFrameSize,
                viewSize: geometry.size
              )
              .frame(width: geometry.size.width, height: geometry.size.height)

              SelectionOverlayView(
                selection: viewModel.currentUnderlineSelection,
                startMarker: viewModel.startMarkerCamera,
                gesturePhase: viewModel.highlightPhase,
                imageSize: viewModel.videoFrameSize,
                viewSize: geometry.size,
                debugTrackingQuad: viewModel.debugTrackingQuad,
                stripSelection: viewModel.highlightStripSelection
              )
              .frame(width: geometry.size.width, height: geometry.size.height)
            }

            // OCR debug region
            if let crop = viewModel.ocrDebugCrop {
              OCRDebugOverlay(
                crop: crop,
                imageSize: viewModel.videoFrameSize,
                viewSize: geometry.size
              )
              .frame(width: geometry.size.width, height: geometry.size.height)
              .allowsHitTesting(false)
            }

            // Page scan debug overlay — dashed rectangles over the regions the detector is
            // currently OCR'ing. Cyan = learning (margin strips), magenta = locked ROI.
            if !viewModel.pageScanDebugCrops.isEmpty {
              PageScanDebugOverlay(
                crops: viewModel.pageScanDebugCrops,
                isLocked: viewModel.pageScanIsLocked,
                imageSize: viewModel.videoFrameSize,
                viewSize: geometry.size
              )
              .frame(width: geometry.size.width, height: geometry.size.height)
              .allowsHitTesting(false)
            }

            // Top-left cluster: page scan status pill stacked above the page
            // progress chip. Either can render on its own; the VStack collapses
            // cleanly when one is absent.
            VStack(alignment: .leading, spacing: 8) {
              if viewModel.pageScanStatus != .idle {
                PageScanStatusChip(status: viewModel.pageScanStatus)
                  .transition(.opacity.combined(with: .move(edge: .top)))
              }
              if viewModel.currentPage != nil || !viewModel.lastRawPageValues.isEmpty {
                PageProgressChip(
                  committedPage: viewModel.currentPage,
                  pagesPerMinute: viewModel.pagesPerMinute,
                  rawValues: viewModel.lastRawPageValues,
                  isLocked: viewModel.pageScanIsLocked
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
              }
              Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)
            .padding(.top, 56)
            .allowsHitTesting(false)
            .animation(.spring(duration: 0.3), value: viewModel.pageScanStatus)

            // Book cover identification overlay — top-center
            CoverIdentificationOverlay(identification: viewModel.bookIdentification)
              .padding(.top, 56)
              .allowsHitTesting(false)

            #if DEBUG
            // Bottom-left diagnostic card showing the last cover capture.
            VStack {
              Spacer()
              HStack {
                CoverDebugCard(identification: viewModel.bookIdentification)
                  .padding(.leading, 16)
                  .padding(.bottom, 140)
                Spacer()
              }
            }
            #endif

            // Word capture toast
            if let word = viewModel.lastCapturedWord {
              VStack {
                Text(word)
                  .font(.system(size: 36, weight: .bold, design: .rounded))
                  .foregroundColor(.white)
                  .padding(.horizontal, 28)
                  .padding(.vertical, 16)
                  .background(.black.opacity(0.75))
                  .clipShape(RoundedRectangle(cornerRadius: 20))
                Spacer()
              }
              .padding(.top, 72)
              .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            // Passage capture toast
            if let passage = viewModel.lastCapturedPassage {
              VStack {
                Spacer()
                Text(passage)
                  .font(.system(size: 18, weight: .medium))
                  .foregroundColor(.white)
                  .lineLimit(4)
                  .multilineTextAlignment(.leading)
                  .padding(16)
                  .background(.black.opacity(0.75))
                  .clipShape(RoundedRectangle(cornerRadius: 12))
                Spacer().frame(height: 100)
              }
              .padding(.horizontal, 24)
              .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
          }
        }
        .edgesIgnoringSafeArea(.all)
        .animation(.spring(duration: 0.3), value: viewModel.lastCapturedWord)
        .animation(.spring(duration: 0.3), value: viewModel.lastCapturedPassage)
      } else {
        ProgressView()
          .scaleEffect(1.5)
          .foregroundColor(.white)
      }

      // OCR crop preview — appears top-right whenever OCR fires
      if let crop = viewModel.currentOCRCrop {
        VStack {
          HStack {
            Spacer()
            Image(uiImage: crop)
              .resizable()
              .aspectRatio(contentMode: .fit)
              .frame(width: 160, height: 80)
              .clipShape(RoundedRectangle(cornerRadius: 10))
              .overlay(
                RoundedRectangle(cornerRadius: 10)
                  .strokeBorder(Color.yellow, lineWidth: 1.5)
              )
              .shadow(radius: 6)
              .padding(.top, 56)
              .padding(.trailing, 16)
          }
          Spacer()
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
        .allowsHitTesting(false)
      }

      // Bottom controls layer

      VStack {
        Spacer()
        ControlsView(viewModel: viewModel)
      }
      .padding(.all, 24)
    }
    .animation(.spring(duration: 0.25), value: viewModel.currentOCRCrop != nil)
    .onDisappear {
      Task {
        if viewModel.streamingStatus != .stopped {
          await viewModel.stopSession()
        }
      }
    }
    // Show captured photos from DAT SDK in a preview sheet
    .sheet(isPresented: $viewModel.showPhotoPreview) {
      if let photo = viewModel.capturedPhoto {
        PhotoPreviewView(
          photo: photo,
          onDismiss: {
            viewModel.dismissPhotoPreview()
          }
        )
      }
    }
  }
}

#if DEBUG
// MARK: - Cover Debug Card

/// DEBUG-only diagnostic card that shows the most recent cover identification
/// attempt: raw OCR lines, Qwen's raw output, the parsed title/author, and
/// which tier produced the final match. Collapsible by tap; auto-hides 30 s
/// after the last capture. Lets the user see pipeline output on-device
/// without needing Xcode console attached.
private struct CoverDebugCard: View {
  @ObservedObject var identification: BookIdentificationService
  @State private var expanded: Bool = true
  @State private var visible: Bool = true
  @State private var autoHideTask: Task<Void, Never>?

  var body: some View {
    Group {
      if let snap = identification.lastCoverDebug, visible {
        VStack(alignment: .leading, spacing: 6) {
          header(snap)
          if expanded {
            Divider().background(Color.white.opacity(0.25))
            ocrSection(snap)
            qwenSection(snap)
            outcomeSection(snap)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 340, alignment: .leading)
        .background(.black.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 2)
        .onTapGesture { expanded.toggle() }
        .onAppear { scheduleAutoHide() }
        .onChange(of: snap.capturedAt) { _, _ in
          visible = true
          scheduleAutoHide()
        }
        .transition(.opacity.combined(with: .move(edge: .leading)))
      }
    }
  }

  private func header(_ snap: CoverDebugSnapshot) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "doc.text.magnifyingglass")
        .font(.system(size: 11, weight: .semibold))
      Text("Last Cover")
        .font(.system(size: 12, weight: .semibold, design: .rounded))
      Spacer()
      Text(timeString(snap.capturedAt))
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundColor(.white.opacity(0.6))
      Image(systemName: expanded ? "chevron.up" : "chevron.down")
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(.white.opacity(0.5))
    }
    .foregroundColor(.white)
  }

  private func ocrSection(_ snap: CoverDebugSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("OCR (\(snap.ocrRawLines.count) lines):")
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(.cyan.opacity(0.9))
      ForEach(Array(snap.ocrRawLines.prefix(8).enumerated()), id: \.offset) { _, line in
        Text("• \(line)")
          .font(.system(size: 10, design: .monospaced))
          .foregroundColor(.white.opacity(0.85))
          .lineLimit(1)
          .truncationMode(.tail)
      }
      if snap.ocrRawLines.count > 8 {
        Text("  +\(snap.ocrRawLines.count - 8) more…")
          .font(.system(size: 9, design: .monospaced))
          .foregroundColor(.white.opacity(0.5))
      }
    }
  }

  private func qwenSection(_ snap: CoverDebugSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Qwen parsed:")
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(.yellow.opacity(0.9))
      Text("T: \(snap.qwenParsedTitle.isEmpty ? "—" : snap.qwenParsedTitle)")
        .font(.system(size: 10, design: .monospaced))
        .foregroundColor(.white.opacity(0.9))
        .lineLimit(1)
      Text("A: \(snap.qwenParsedAuthor.isEmpty ? "—" : snap.qwenParsedAuthor)")
        .font(.system(size: 10, design: .monospaced))
        .foregroundColor(.white.opacity(0.9))
        .lineLimit(1)
      if !snap.qwenRawOutput.isEmpty {
        Text("raw:")
          .font(.system(size: 9, weight: .semibold))
          .foregroundColor(.white.opacity(0.5))
        Text(snap.qwenRawOutput)
          .font(.system(size: 9, design: .monospaced))
          .foregroundColor(.white.opacity(0.6))
          .lineLimit(6)
      }
    }
  }

  private func outcomeSection(_ snap: CoverDebugSnapshot) -> some View {
    HStack(spacing: 4) {
      let isSuccess = !snap.matchOutcome.hasPrefix("failed")
      Image(systemName: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(isSuccess ? .green : .red)
      Text(snap.matchOutcome)
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .foregroundColor(.white)
        .lineLimit(2)
    }
  }

  private func timeString(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: date)
  }

  private func scheduleAutoHide() {
    autoHideTask?.cancel()
    autoHideTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 30_000_000_000)
      if !Task.isCancelled {
        visible = false
      }
    }
  }
}
#endif

// MARK: - Cover Identification Overlay

/// Top-center overlay that surfaces book-cover identification state. Shown as
/// a pill that transitions between identifying / matched / failed phases.
/// The view observes BookIdentificationService directly so its @Published phase
/// drives the animation without needing StreamSessionViewModel republishing.
private struct CoverIdentificationOverlay: View {
  @ObservedObject var identification: BookIdentificationService
  @State private var visibleMatchedBookTitle: String?
  @State private var visibleMatchedBookAuthor: String?
  @State private var dismissTask: Task<Void, Never>?

  var body: some View {
    VStack {
      switch identification.phase {
      case .idle:
        EmptyView()
      case .identifying:
        pill(icon: "book.closed", text: "Identifying book…", tint: .white)
      case .matched:
        if let title = visibleMatchedBookTitle {
          matchedPill(title: title, author: visibleMatchedBookAuthor)
        }
      case .needsDisambiguation(let candidates):
        pill(
          icon: "questionmark.circle",
          text: "\(candidates.count) possible match\(candidates.count == 1 ? "" : "es")",
          tint: .yellow
        )
      case .failed(let err):
        pill(icon: "exclamationmark.triangle", text: message(for: err), tint: .orange)
      }
      Spacer()
    }
    .frame(maxWidth: .infinity)
    .animation(.spring(duration: 0.35), value: phaseKey)
    .onChange(of: phaseKey) { _, _ in
      handlePhaseChange()
    }
    .onAppear {
      handlePhaseChange()
    }
  }

  /// A stable String key that changes whenever we want the view to animate.
  private var phaseKey: String {
    switch identification.phase {
    case .idle: "idle"
    case .identifying: "identifying"
    case .matched(let book, _): "matched:\(book.persistentModelID.hashValue)"
    case .needsDisambiguation(let list): "picker:\(list.count)"
    case .failed(let err): "failed:\(err)"
    }
  }

  private func handlePhaseChange() {
    dismissTask?.cancel()
    if case .matched(let book, _) = identification.phase {
      visibleMatchedBookTitle = book.title
      visibleMatchedBookAuthor = book.author.isEmpty ? nil : book.author
      // Auto-hide the matched pill after 3 seconds by forcing a re-render.
      dismissTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if !Task.isCancelled {
          visibleMatchedBookTitle = nil
          visibleMatchedBookAuthor = nil
        }
      }
    } else {
      visibleMatchedBookTitle = nil
      visibleMatchedBookAuthor = nil
    }
  }

  private func message(for error: IdentificationError) -> String {
    switch error {
    case .offline: return "Saved — will identify when online"
    case .noResults: return "No match found"
    case .modelNotReady: return "AI model still loading"
    case .ocrEmpty: return "Couldn't read cover"
    case .networkFailed: return "Identification failed"
    case .canonicalizationFailed: return "Couldn't process cover"
    }
  }

  // MARK: - Pill styles

  private func pill(icon: String, text: String, tint: Color) -> some View {
    HStack(spacing: 8) {
      Image(systemName: icon)
        .font(.system(size: 13, weight: .semibold))
      Text(text)
        .font(.system(size: 14, weight: .semibold, design: .rounded))
    }
    .foregroundColor(tint)
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(.black.opacity(0.7))
    .clipShape(Capsule())
    .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 2)
    .transition(.opacity.combined(with: .move(edge: .top)))
  }

  private func matchedPill(title: String, author: String?) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 18, weight: .semibold))
        .foregroundColor(.green)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 15, weight: .semibold, design: .serif))
          .foregroundColor(.white)
          .lineLimit(1)
        if let author {
          Text(author)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.75))
            .lineLimit(1)
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(.black.opacity(0.75))
    .clipShape(RoundedRectangle(cornerRadius: 14))
    .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 3)
    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
  }
}

// MARK: - Page Progress Chip

struct PageProgressChip: View {
  let committedPage: Int?
  let pagesPerMinute: Double?
  let rawValues: [Int]
  let isLocked: Bool

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: isLocked ? "lock.fill" : "book.pages")
        .font(.system(size: 12, weight: .semibold))
      if let page = committedPage {
        Text("p. \(page)")
          .font(.system(size: 14, weight: .semibold, design: .rounded))
      } else {
        Text("learning…")
          .font(.system(size: 12, weight: .medium, design: .rounded))
          .foregroundColor(.white.opacity(0.7))
      }
      if let pace = pagesPerMinute, pace.isFinite, pace > 0 {
        Text("·")
          .foregroundColor(.white.opacity(0.4))
        Text(String(format: "%.1f pg/min", pace))
          .font(.system(size: 12, weight: .medium, design: .rounded))
          .foregroundColor(.white.opacity(0.85))
      }
      if !rawValues.isEmpty {
        Text("·")
          .foregroundColor(.white.opacity(0.4))
        Text("raw \(rawValues.map(String.init).joined(separator: ","))")
          .font(.system(size: 11, weight: .regular, design: .monospaced))
          .foregroundColor(.yellow.opacity(0.9))
      }
    }
    .foregroundColor(.white)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.black.opacity(0.65))
    .clipShape(Capsule())
  }
}

// MARK: - Page Scan Status Chip

/// Pill that mirrors `CoverIdentificationOverlay` styling and surfaces the
/// page-number detector's state: a spinner + "Searching for page number…"
/// while the ROI is being learned, a green check + "Page number located"
/// briefly after the ROI commits. Hidden entirely when `.idle`.
struct PageScanStatusChip: View {
  let status: PageScanStatus

  var body: some View {
    HStack(spacing: 8) {
      switch status {
      case .searching:
        ProgressView()
          .controlSize(.small)
          .tint(.white)
        Text("Searching for page number…")
          .font(.system(size: 13, weight: .medium, design: .rounded))
          .foregroundColor(.white)
      case .located:
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(.green)
        Text("Page number located")
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .foregroundColor(.white)
      case .idle:
        EmptyView()
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .background(.black.opacity(0.7))
    .clipShape(Capsule())
    .shadow(color: .black.opacity(0.35), radius: 5, x: 0, y: 2)
  }
}

// MARK: - Page Scan Debug Overlay

/// Draws dashed outlines over the regions the page-number detector is currently
/// OCR'ing — the margin strips during learning, or the tight learned rect once locked.
/// Uses the same camera → view coordinate transform as the other debug overlays.
struct PageScanDebugOverlay: View {
  let crops: [OrientedCrop]
  let isLocked: Bool
  let imageSize: CGSize
  let viewSize: CGSize

  var body: some View {
    Canvas { context, _ in
      guard imageSize.width > 0, imageSize.height > 0 else { return }
      let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
      let scaledW = imageSize.width * scale
      let scaledH = imageSize.height * scale
      let offX = (scaledW - viewSize.width) / 2
      let offY = (scaledH - viewSize.height) / 2

      func convert(_ p: CGPoint) -> CGPoint {
        CGPoint(
          x: p.x * scaledW - offX,
          y: (1.0 - p.y) * scaledH - offY
        )
      }

      let stroke = isLocked ? Color(red: 1, green: 0, blue: 0.85) : Color.cyan
      let dash: [CGFloat] = isLocked ? [2, 2] : [5, 3]
      let width: CGFloat = isLocked ? 2.5 : 1.5

      for crop in crops {
        let pts = crop.corners.map(convert)
        guard pts.count == 4 else { continue }
        var path = Path()
        path.move(to: pts[0])
        for pt in pts.dropFirst() { path.addLine(to: pt) }
        path.closeSubpath()
        context.stroke(path, with: .color(stroke), style: StrokeStyle(lineWidth: width, dash: dash))
      }
    }
  }
}

// MARK: - OCR Debug Overlay

struct OCRDebugOverlay: View {
  let crop: OrientedCrop   // Vision normalized coords (0–1, bottom-left origin)
  let imageSize: CGSize
  let viewSize: CGSize

  var body: some View {
    Canvas { context, _ in
      guard imageSize.width > 0, imageSize.height > 0 else { return }
      let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
      let scaledW = imageSize.width * scale
      let scaledH = imageSize.height * scale
      let offX = (scaledW - viewSize.width) / 2
      let offY = (scaledH - viewSize.height) / 2

      func convert(_ p: CGPoint) -> CGPoint {
        CGPoint(
          x: p.x * scaledW - offX,
          y: (1.0 - p.y) * scaledH - offY
        )
      }

      let pts = crop.corners.map(convert)
      guard pts.count == 4 else { return }

      var path = Path()
      path.move(to: pts[0])
      for pt in pts.dropFirst() { path.addLine(to: pt) }
      path.closeSubpath()
      context.stroke(path, with: .color(.yellow), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))

      // Cross-hair at the crop center
      let center = convert(crop.center)
      var cross = Path()
      cross.move(to: CGPoint(x: center.x - 8, y: center.y))
      cross.addLine(to: CGPoint(x: center.x + 8, y: center.y))
      cross.move(to: CGPoint(x: center.x, y: center.y - 8))
      cross.addLine(to: CGPoint(x: center.x, y: center.y + 8))
      context.stroke(cross, with: .color(.yellow), lineWidth: 2)
    }
  }
}

// Extracted controls for clarity
struct ControlsView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @State private var showCapturedWords = false
  @State private var showCapturedPassages = false

  var body: some View {
    // Controls row
    HStack(spacing: 8) {
      CustomButton(
        title: "Stop streaming",
        style: .destructive,
        isDisabled: false
      ) {
        Task {
          await viewModel.stopSession()
        }
      }

      // Photo button
      CircleButton(icon: "camera.fill", text: nil) {
        viewModel.capturePhoto()
      }

      // Review captured words
      CircleButton(icon: "list.bullet", text: nil) {
        showCapturedWords = true
      }

      // Review highlighted passages
      CircleButton(icon: "text.highlight", text: nil) {
        showCapturedPassages = true
      }
    }
    .sheet(isPresented: $showCapturedWords) {
      CapturedWordsView()
        .modelContainer(AppContainer.shared)
    }
    .sheet(isPresented: $showCapturedPassages) {
      CapturedPassagesView()
        .modelContainer(AppContainer.shared)
    }
  }
}
