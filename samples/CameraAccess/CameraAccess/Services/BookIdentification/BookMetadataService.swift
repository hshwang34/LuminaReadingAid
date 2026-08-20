//
// BookMetadataService.swift
//
// Thin async actor wrapping the Open Library Search API. Returns candidates
// for disambiguation or auto-pick. Hard 4s request timeout, one retry on
// transient failures, surfaces offline errors directly so the orchestrator
// can queue a PendingCoverIdentification instead of retrying.
//

import Foundation

struct BookMetadataCandidate: Sendable {
  let title: String
  let author: String
  let isbn13: String?
  let openLibraryWorkId: String?
  let coverImageURL: URL?
  let editionCount: Int
  var fuzzyScore: Double
}

actor BookMetadataService {

  enum MetadataError: LocalizedError {
    case offline
    case noResults
    case apiError(Int)
    case parseError
    case timeout

    var errorDescription: String? {
      switch self {
      case .offline: "No network connection."
      case .noResults: "No matching books found."
      case .apiError(let code): "Open Library returned error \(code)."
      case .parseError: "Could not parse Open Library response."
      case .timeout: "Open Library request timed out."
      }
    }
  }

  private let session: URLSession

  init() {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 4.0
    config.timeoutIntervalForResource = 6.0
    config.waitsForConnectivity = false
    self.session = URLSession(configuration: config)
  }

  // MARK: - Search

  /// Queries Open Library Search API. Uses typed `title=` + `author=` fields
  /// when both are non-trivial; falls back to `q=` full-text search otherwise
  /// (which also handles the "Qwen not ready, raw OCR blob as title" case).
  func search(title: String, author: String) async throws -> [BookMetadataCandidate] {
    let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
    guard trimmedTitle.count >= 2 else { throw MetadataError.noResults }
    let trimmedAuthor = author.trimmingCharacters(in: .whitespaces)

    var components = URLComponents(string: "https://openlibrary.org/search.json")!
    var queryItems: [URLQueryItem] = [
      URLQueryItem(name: "limit", value: "5"),
      URLQueryItem(name: "fields", value: "key,title,author_name,cover_i,edition_count,isbn"),
    ]
    if trimmedAuthor.count >= 3 {
      queryItems.append(URLQueryItem(name: "title", value: trimmedTitle))
      queryItems.append(URLQueryItem(name: "author", value: trimmedAuthor))
    } else {
      queryItems.append(URLQueryItem(name: "q", value: trimmedTitle))
    }
    components.queryItems = queryItems

    guard let url = components.url else { throw MetadataError.parseError }

    let data = try await fetchWithRetry(url: url)

    let decoded: SearchResponse
    do {
      decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
    } catch {
      throw MetadataError.parseError
    }

    let candidates: [BookMetadataCandidate] = decoded.docs.map { doc in
      let isbn13 = doc.isbn?.first(where: { $0.count == 13 })
      let workID: String? = doc.key.flatMap { key in
        // "/works/OL24894477W" → "OL24894477W"
        key.split(separator: "/").last.map(String.init)
      }
      let coverURL: URL? = doc.cover_i.flatMap { coverID in
        URL(string: "https://covers.openlibrary.org/b/id/\(coverID)-L.jpg")
      }
      return BookMetadataCandidate(
        title: doc.title ?? "",
        author: doc.author_name?.first ?? "",
        isbn13: isbn13,
        openLibraryWorkId: workID,
        coverImageURL: coverURL,
        editionCount: doc.edition_count ?? 0,
        fuzzyScore: 0
      )
    }

    guard !candidates.isEmpty else { throw MetadataError.noResults }
    return candidates
  }

  // MARK: - Cover fetch

  /// Downloads cover bytes from covers.openlibrary.org. URLSession follows
  /// the 302 to the CDN automatically.
  func fetchCoverImage(_ url: URL) async throws -> Data {
    do {
      let (data, response) = try await session.data(from: url)
      guard let http = response as? HTTPURLResponse else {
        throw MetadataError.apiError(-1)
      }
      guard http.statusCode == 200 else {
        throw MetadataError.apiError(http.statusCode)
      }
      return data
    } catch let urlError as URLError {
      switch urlError.code {
      case .notConnectedToInternet, .dataNotAllowed:
        throw MetadataError.offline
      case .timedOut:
        throw MetadataError.timeout
      default:
        throw MetadataError.apiError(urlError.code.rawValue)
      }
    }
  }

  // MARK: - Private HTTP

  private func fetchWithRetry(url: URL) async throws -> Data {
    do {
      return try await fetch(url: url)
    } catch MetadataError.offline {
      throw MetadataError.offline  // don't retry when offline
    } catch {
      try? await Task.sleep(nanoseconds: 600_000_000)
      return try await fetch(url: url)
    }
  }

  private func fetch(url: URL) async throws -> Data {
    do {
      let (data, response) = try await session.data(from: url)
      guard let http = response as? HTTPURLResponse else {
        throw MetadataError.apiError(-1)
      }
      if http.statusCode == 200 { return data }
      throw MetadataError.apiError(http.statusCode)
    } catch let urlError as URLError {
      switch urlError.code {
      case .notConnectedToInternet, .dataNotAllowed:
        throw MetadataError.offline
      case .timedOut:
        throw MetadataError.timeout
      default:
        throw MetadataError.apiError(urlError.code.rawValue)
      }
    }
  }
}

// MARK: - Open Library response

private struct SearchResponse: Decodable {
  let docs: [SearchDoc]
}

private struct SearchDoc: Decodable {
  let key: String?
  let title: String?
  let author_name: [String]?
  let cover_i: Int?
  let edition_count: Int?
  let isbn: [String]?
}
