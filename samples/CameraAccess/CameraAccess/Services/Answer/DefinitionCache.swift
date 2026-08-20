//
// DefinitionCache.swift
//
// Keeps dictionary lookups off the latency path.
//
// A cache hit turns the 150-400ms network leg of an answer into zero, which is the
// difference between comfortably hitting the time-to-first-audio budget and missing
// it. It also keeps the session usable when dictionaryapi.dev is slow or unreachable,
// which matters because that service has no SLA and the reader is mid-sentence.
//
// Definitions don't change, so entries never expire; the cache is bounded by count
// instead, dropping the oldest insertions when it overflows.
//

import Foundation

actor DefinitionCache {

  static let shared = DefinitionCache()

  /// Roughly a heavy reader's lifetime vocabulary; the on-disk file stays well under
  /// a megabyte at this size.
  private let capacity: Int
  private var entries: [String: [DictionarySense]] = [:]
  /// Insertion order, oldest first, for eviction.
  private var order: [String] = []

  private var loaded = false
  private var dirty = false
  private var flushTask: Task<Void, Never>?

  private let fileURL: URL

  init(capacity: Int = 2000, fileURL: URL? = nil) {
    self.capacity = capacity
    self.fileURL = fileURL ?? Self.defaultFileURL()
  }

  private static func defaultFileURL() -> URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return caches.appendingPathComponent("definition-cache.json")
  }

  // MARK: - Lookup

  func senses(for word: String) -> [DictionarySense]? {
    loadIfNeeded()
    return entries[Self.key(word)]
  }

  func store(_ senses: [DictionarySense], for word: String) {
    guard !senses.isEmpty else { return }
    loadIfNeeded()

    let key = Self.key(word)
    if entries[key] == nil {
      order.append(key)
    }
    entries[key] = senses
    evictIfNeeded()
    dirty = true
    scheduleFlush()
  }

  func contains(_ word: String) -> Bool {
    loadIfNeeded()
    return entries[Self.key(word)] != nil
  }

  func clear() {
    entries.removeAll()
    order.removeAll()
    dirty = true
    scheduleFlush()
  }

  private func evictIfNeeded() {
    while order.count > capacity, let oldest = order.first {
      order.removeFirst()
      entries.removeValue(forKey: oldest)
    }
  }

  private static func key(_ word: String) -> String {
    word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  // MARK: - Persistence

  private struct Payload: Codable {
    let order: [String]
    let entries: [String: [DictionarySense]]
  }

  private func loadIfNeeded() {
    guard !loaded else { return }
    loaded = true

    guard let data = try? Data(contentsOf: fileURL),
          let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
      return
    }
    entries = payload.entries
    // Trust the file's order but drop any keys that fell out of sync.
    order = payload.order.filter { entries[$0] != nil }
    for key in entries.keys where !order.contains(key) {
      order.append(key)
    }
    evictIfNeeded()
  }

  /// Writes are debounced: a burst of lookups during one exchange produces a single
  /// disk write a few seconds later rather than one per word.
  private func scheduleFlush() {
    flushTask?.cancel()
    flushTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      await self?.flush()
    }
  }

  /// Force a write. Called at session end so nothing is lost if the app is killed
  /// while backgrounded.
  func flush() {
    guard dirty else { return }
    dirty = false

    let payload = Payload(order: order, entries: entries)
    guard let data = try? JSONEncoder().encode(payload) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
