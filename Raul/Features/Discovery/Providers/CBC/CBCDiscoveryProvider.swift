//
//  CBCDiscoveryProvider.swift
//  Raul
//
//  Discovery for CBC (Canada), backed by CBC's public podcast directory.
//  Every show there publishes an ordinary RSS feed, so browsing, categories and
//  search all read one cached document and a subscription needs no extra step.
//

import Foundation

struct CBCDiscoveryProvider: PodcastDiscoveryProvider {
    let broadcaster: PublicBroadcaster
    private let client: PodcastDiscoveryHTTPClient
    private let cache: PodcastDiscoveryCache

    var id: String { broadcaster.id }

    var capabilities: PodcastDiscoveryCapabilities {
        [.categories, .allPodcasts, .search, .feedURL]
    }

    init(
        broadcaster: PublicBroadcaster,
        client: PodcastDiscoveryHTTPClient = .shared,
        cache: PodcastDiscoveryCache = .shared
    ) {
        self.broadcaster = broadcaster
        self.client = client
        self.cache = cache
    }

    func allPodcasts(refresh: Bool) async throws -> [DiscoveredPodcast] {
        try await cache.cached("cbc.catalog", refresh: refresh) {
            guard let directoryURL = CBCDirectoryParser.directoryURL else {
                throw PodcastDiscoveryError.unavailable
            }

            let markup = try await client.markup(from: directoryURL, refresh: refresh)
            let podcasts = CBCDirectoryParser.parseDirectory(
                markup: markup,
                providerID: id,
                broadcasterID: broadcaster.id
            )

            guard podcasts.isEmpty == false else {
                throw PodcastDiscoveryError.parsingFailed
            }

            return podcasts
        }
    }

    func categories(refresh: Bool) async throws -> [PodcastDiscoveryCategory] {
        let podcasts = try await allPodcasts(refresh: refresh)
        return CBCDirectoryParser.categories(from: podcasts, providerID: id)
    }

    func podcasts(in category: PodcastDiscoveryCategory, refresh: Bool) async throws -> [DiscoveredPodcast] {
        let podcasts = try await allPodcasts(refresh: refresh)
        return podcasts.filter { $0.providerReference == category.id }
    }

    func search(_ query: String) async throws -> [DiscoveredPodcast] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        let podcasts = try await allPodcasts(refresh: false)
        return podcasts.matchingDiscoveryQuery(trimmed)
    }
}
