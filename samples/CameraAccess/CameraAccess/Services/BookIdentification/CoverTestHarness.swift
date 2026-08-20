//
// CoverTestHarness.swift
//
// DEBUG-only automated test harness for the book-cover identification
// pipeline. Fetches ~100 popular book covers from Open Library, runs each
// cover image through BookCoverOCRService (Vision OCR + Qwen), and compares
// the extracted title/author against the ground truth supplied by Open
// Library itself. Skips CoverCanonicalizer since Open Library covers are
// already clean upright rectangles — we want to test the OCR + Qwen path
// specifically, not the perspective warp.
//

#if DEBUG
import SwiftUI
import Foundation
import CoreGraphics
import ImageIO

// MARK: - Types

struct CoverTestFixture: Identifiable, Sendable {
  let id = UUID()
  let expectedTitle: String
  let expectedAuthor: String
  let coverImageURL: URL
}

struct CoverTestResult: Identifiable {
  let id = UUID()
  let fixture: CoverTestFixture
  let qwenTitle: String
  let qwenAuthor: String
  let qwenRawOutput: String
  let ocrLineCount: Int
  let titleScore: Double
  let authorScore: Double
  let verdict: Verdict

  enum Verdict: String {
    case pass = "✅"
    case partialTitle = "⚠️ T"
    case partialAuthor = "⚠️ A"
    case fail = "❌"
    case emptyOCR = "🫥"
    case fetchError = "🌐"
    case decodeError = "🖼"
  }
}

// MARK: - Runner

@MainActor
final class CoverTestHarness: ObservableObject {
  @Published var fixtures: [CoverTestFixture] = []
  @Published var results: [CoverTestResult] = []
  @Published var isRunning: Bool = false
  @Published var currentIndex: Int = 0
  @Published var status: String = "idle"

  private let ocrService = BookCoverOCRService()

  /// Pull top-rated fiction books with covers from Open Library.
  private let fixtureFetchURL = URL(string:
    "https://openlibrary.org/search.json?subject=fiction&language=eng&sort=rating&fields=title,author_name,cover_i&limit=100"
  )!

  /// Minimum fuzzy score (0..1) for a field to count as "correct."
  private let passThreshold: Double = 0.70

  var tier1PassCount: Int {
    results.filter { $0.verdict == .pass }.count
  }
  var titlePassCount: Int {
    results.filter { $0.titleScore >= passThreshold }.count
  }
  var authorPassCount: Int {
    results.filter { $0.authorScore >= passThreshold }.count
  }
  var totalCount: Int { results.count }

  // MARK: Fixture loading

  func loadFixtures() async {
    status = "fetching fixture list…"
    do {
      let (data, _) = try await URLSession.shared.data(from: fixtureFetchURL)
      let decoded = try JSONDecoder().decode(FixtureFetchResponse.self, from: data)
      let loaded: [CoverTestFixture] = decoded.docs.compactMap { doc in
        guard let title = doc.title, !title.isEmpty,
              let author = doc.author_name?.first, !author.isEmpty,
              let coverID = doc.cover_i,
              let url = URL(string: "https://covers.openlibrary.org/b/id/\(coverID)-L.jpg")
        else { return nil }
        return CoverTestFixture(
          expectedTitle: title,
          expectedAuthor: author,
          coverImageURL: url
        )
      }
      fixtures = loaded
      status = "\(loaded.count) fixtures ready"
    } catch {
      status = "fixture fetch failed: \(error.localizedDescription)"
    }
  }

  // MARK: Test run

  func runAll() async {
    guard !fixtures.isEmpty else { return }
    isRunning = true
    results.removeAll()
    currentIndex = 0
    status = "running…"

    for (i, fixture) in fixtures.enumerated() {
      if Task.isCancelled { break }
      currentIndex = i
      let result = await runOne(fixture)
      results.append(result)
      await Task.yield()
    }

    isRunning = false
    status = "done — \(tier1PassCount)/\(totalCount) pass "
      + "(title \(titlePassCount), author \(authorPassCount))"
  }

  private func runOne(_ fixture: CoverTestFixture) async -> CoverTestResult {
    // 1. Fetch cover bytes.
    let data: Data
    do {
      let (fetched, response) = try await URLSession.shared.data(from: fixture.coverImageURL)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        return fail(fixture, verdict: .fetchError)
      }
      data = fetched
    } catch {
      return fail(fixture, verdict: .fetchError)
    }

    // 2. Decode to CGImage.
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      return fail(fixture, verdict: .decodeError)
    }

    // 3. Run OCR + Qwen extraction — the part we actually want to stress-test.
    let ocrResult: CoverOCRResult
    do {
      ocrResult = try await ocrService.recognize(canonicalCover: cgImage)
    } catch {
      return fail(fixture, verdict: .emptyOCR)
    }

    if ocrResult.rawLines.isEmpty {
      return fail(fixture, verdict: .emptyOCR)
    }

    // 4. Score against ground truth using the same fuzzy function the
    //    production matcher uses — so these scores are directly comparable.
    let titleScore = CoverMatching.fuzzyScore(ocrResult.title, fixture.expectedTitle)
    let authorScore = CoverMatching.fuzzyScore(ocrResult.author, fixture.expectedAuthor)

    let verdict: CoverTestResult.Verdict
    if titleScore >= passThreshold && authorScore >= passThreshold {
      verdict = .pass
    } else if titleScore >= passThreshold {
      verdict = .partialTitle
    } else if authorScore >= passThreshold {
      verdict = .partialAuthor
    } else {
      verdict = .fail
    }

    return CoverTestResult(
      fixture: fixture,
      qwenTitle: ocrResult.title,
      qwenAuthor: ocrResult.author,
      qwenRawOutput: ocrResult.llmRawOutput,
      ocrLineCount: ocrResult.rawLines.count,
      titleScore: titleScore,
      authorScore: authorScore,
      verdict: verdict
    )
  }

  private func fail(_ fixture: CoverTestFixture, verdict: CoverTestResult.Verdict) -> CoverTestResult {
    CoverTestResult(
      fixture: fixture,
      qwenTitle: "",
      qwenAuthor: "",
      qwenRawOutput: "",
      ocrLineCount: 0,
      titleScore: 0,
      authorScore: 0,
      verdict: verdict
    )
  }
}

// MARK: - Fixture decode types

private struct FixtureFetchResponse: Decodable {
  let docs: [FixtureFetchDoc]
}

private struct FixtureFetchDoc: Decodable {
  let title: String?
  let author_name: [String]?
  let cover_i: Int?
}

// MARK: - UI

struct CoverTestHarnessView: View {
  @StateObject private var harness = CoverTestHarness()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      headerCard
      Divider()
      if harness.results.isEmpty {
        emptyState
      } else {
        resultsList
      }
    }
    .navigationTitle("Cover Test Harness")
    .navigationBarTitleDisplayMode(.inline)
    .task {
      if harness.fixtures.isEmpty {
        await harness.loadFixtures()
      }
    }
  }

  // MARK: Header

  private var headerCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(harness.status)
          .font(.system(size: 12, weight: .medium, design: .monospaced))
          .foregroundColor(.secondary)
          .lineLimit(2)
        Spacer()
        if harness.isRunning {
          ProgressView().scaleEffect(0.8)
        }
      }

      if !harness.results.isEmpty {
        let pass = harness.tier1PassCount
        let total = harness.totalCount
        let percent = total > 0 ? Double(pass) / Double(total) * 100 : 0
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text("\(pass)/\(total)")
            .font(.system(size: 22, weight: .bold, design: .rounded))
          Text(String(format: "%.0f%% pass", percent))
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundColor(passColor(for: percent))
          Spacer()
          VStack(alignment: .trailing, spacing: 2) {
            Text("title \(harness.titlePassCount)/\(total)")
              .font(.system(size: 10, design: .monospaced))
              .foregroundColor(.secondary)
            Text("author \(harness.authorPassCount)/\(total)")
              .font(.system(size: 10, design: .monospaced))
              .foregroundColor(.secondary)
          }
        }
      } else if !harness.fixtures.isEmpty {
        Text("\(harness.fixtures.count) fixtures ready")
          .font(.system(size: 12, design: .rounded))
          .foregroundColor(.secondary)
      }

      if harness.isRunning {
        ProgressView(value: Double(harness.currentIndex + 1),
                     total: Double(max(harness.fixtures.count, 1)))
      }

      HStack(spacing: 10) {
        Button("Reload") {
          Task { await harness.loadFixtures() }
        }
        .buttonStyle(.bordered)
        .disabled(harness.isRunning)

        Button(harness.isRunning ? "Running…" : "Run All") {
          Task { await harness.runAll() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(harness.isRunning || harness.fixtures.isEmpty)
      }
    }
    .padding()
  }

  private func passColor(for percent: Double) -> Color {
    if percent >= 70 { return .green }
    if percent >= 40 { return .orange }
    return .red
  }

  // MARK: States

  private var emptyState: some View {
    VStack(spacing: 12) {
      Spacer()
      Image(systemName: "books.vertical")
        .font(.system(size: 44))
        .foregroundColor(.secondary)
      Text(harness.fixtures.isEmpty
           ? "Loading fixtures from Open Library…"
           : "Ready. Tap Run All to start.")
        .font(.callout)
        .foregroundColor(.secondary)
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  private var resultsList: some View {
    List(harness.results) { result in
      CoverTestResultRow(result: result)
    }
    .listStyle(.plain)
  }
}

private struct CoverTestResultRow: View {
  let result: CoverTestResult
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(result.verdict.rawValue)
          .font(.system(size: 14))
          .frame(width: 28, alignment: .leading)
        Text(result.fixture.expectedTitle)
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
        Spacer()
        Image(systemName: expanded ? "chevron.up" : "chevron.down")
          .font(.system(size: 10))
          .foregroundColor(.secondary)
      }
      if expanded {
        VStack(alignment: .leading, spacing: 3) {
          Group {
            Text("expected: \(result.fixture.expectedTitle)")
            Text("      by: \(result.fixture.expectedAuthor)")
          }
          .font(.system(size: 11, design: .monospaced))
          .foregroundColor(.secondary)
          Group {
            Text("   qwen T: \(result.qwenTitle.isEmpty ? "—" : result.qwenTitle)")
            Text("   qwen A: \(result.qwenAuthor.isEmpty ? "—" : result.qwenAuthor)")
          }
          .font(.system(size: 11, design: .monospaced))
          .foregroundColor(.primary)
          Text(String(format: "scores: title %.2f  author %.2f  ocr lines %d",
                      result.titleScore, result.authorScore, result.ocrLineCount))
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.secondary)
        }
        .padding(.leading, 28)
      }
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .onTapGesture { expanded.toggle() }
  }
}
#endif
