//
//  PodcastDiscoveryService.swift
//  Raul
//
//  Cross-provider operations: searching every searchable broadcaster at once and
//  resolving a discovered show to an ordinary RSS feed.
//

import Foundation

struct PodcastDiscoveryService: Sendable {
    let registry: PodcastDiscoveryRegistry

    init(registry: PodcastDiscoveryRegistry = .shared) {
        self.registry = registry
    }

    /// Searches every provider that supports search, concurrently.
    ///
    /// A provider that fails or times out contributes nothing and is otherwise
    /// ignored: one broken integration must never empty the whole result list.
    func search(_ query: String) async -> [DiscoveredPodcast] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        let providers = registry.searchableProviders
        guard providers.isEmpty == false else { return [] }

        let resultsByProvider = await withTaskGroup(
            of: (String, [DiscoveredPodcast]).self,
            returning: [String: [DiscoveredPodcast]].self
        ) { group in
            for provider in providers {
                group.addTask {
                    do {
                        return (provider.id, try await provider.search(trimmed))
                    } catch {
                        // Contained on purpose: the other providers still answer.
                        return (provider.id, [])
                    }
                }
            }

            var collected: [String: [DiscoveredPodcast]] = [:]
            for await (providerID, podcasts) in group {
                collected[providerID] = podcasts
            }
            return collected
        }

        // Rebuild in catalog order so ranking ties are stable regardless of
        // which provider happened to answer first.
        let ordered = providers.flatMap { resultsByProvider[$0.id] ?? [] }

        return Self.rank(ordered, for: trimmed, registry: registry)
    }

    /// Orders results by how directly they answer the query, then de-duplicates
    /// shows that several providers report with the same RSS feed.
    static func rank(
        _ podcasts: [DiscoveredPodcast],
        for query: String,
        registry: PodcastDiscoveryRegistry
    ) -> [DiscoveredPodcast] {
        let key = query.discoveryComparisonKey

        let scored = podcasts.enumerated().map { index, podcast -> (score: Int, index: Int, podcast: DiscoveredPodcast) in
            (score(for: podcast, queryKey: key, registry: registry), index, podcast)
        }

        let sorted = scored.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score < rhs.score
        }

        var seen = Set<String>()
        var deduplicated: [DiscoveredPodcast] = []

        for entry in sorted where seen.insert(entry.podcast.deduplicationKey).inserted {
            deduplicated.append(entry.podcast)
        }

        return deduplicated
    }

    private static func score(
        for podcast: DiscoveredPodcast,
        queryKey: String,
        registry: PodcastDiscoveryRegistry
    ) -> Int {
        guard queryKey.isEmpty == false else { return 4 }

        let titleKey = podcast.title.discoveryComparisonKey

        if titleKey == queryKey { return 0 }
        if titleKey.hasPrefix(queryKey) { return 1 }
        if titleKey.contains(queryKey) { return 2 }

        // Someone searching for a broadcaster's name wants that broadcaster's shows.
        if let broadcaster = registry.broadcaster(withID: podcast.broadcasterID),
           broadcaster.name.discoveryComparisonKey.contains(queryKey) {
            return 3
        }

        return 4
    }

    /// Resolves the RSS feed for a discovered show, so the existing feed import
    /// path can take over from here.
    func resolveFeed(for podcast: DiscoveredPodcast) async throws -> URL {
        guard let provider = registry.provider(for: podcast.broadcasterID) else {
            throw PodcastDiscoveryError.unavailable
        }

        return try await provider.resolveFeed(for: podcast)
    }
}
