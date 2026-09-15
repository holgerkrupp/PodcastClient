//
//  PodcastDiscoveryCache.swift
//  Raul
//
//  Short-lived in-memory cache for discovery catalogues. Discovery data is not
//  persisted in SwiftData: it is remote catalogue data, not library content, and
//  it is cheap to fetch again after the lifetime expires.
//

import Foundation

actor PodcastDiscoveryCache {
    static let shared = PodcastDiscoveryCache()

    /// Catalogues change rarely; a few hours keeps navigation free of refetching.
    static let catalogLifetime: TimeInterval = 6 * 60 * 60
    /// Search results age out much faster.
    static let searchLifetime: TimeInterval = 5 * 60

    private struct Entry {
        let value: any Sendable
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func value<Value: Sendable>(_ type: Value.Type = Value.self, for key: String) -> Value? {
        guard let entry = entries[key] else { return nil }

        guard entry.expiresAt > now() else {
            entries[key] = nil
            return nil
        }

        return entry.value as? Value
    }

    func store<Value: Sendable>(_ value: Value, for key: String, lifetime: TimeInterval) {
        entries[key] = Entry(value: value, expiresAt: now().addingTimeInterval(lifetime))
    }

    func remove(for key: String) {
        entries[key] = nil
    }

    func removeAll() {
        entries.removeAll()
    }

    /// Returns the cached value, or builds and caches a fresh one.
    /// `refresh` bypasses (and replaces) whatever is cached.
    func cached<Value: Sendable>(
        _ key: String,
        lifetime: TimeInterval = PodcastDiscoveryCache.catalogLifetime,
        refresh: Bool = false,
        build: @Sendable () async throws -> Value
    ) async throws -> Value {
        if refresh == false, let cached: Value = value(for: key) {
            return cached
        }

        let value = try await build()
        store(value, for: key, lifetime: lifetime)
        return value
    }
}
