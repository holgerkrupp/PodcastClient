//
//  ORFDiscoveryProvider.swift
//  Raul
//
//  Discovery for ORF (Austria), backed by ORF Sound's public podcast directory
//  endpoint. The whole catalogue arrives in one request and carries the RSS feed
//  for every show, so browsing, categories and search all read the same cached
//  catalogue and no scraping is involved.
//

import Foundation

struct ORFDiscoveryProvider: PodcastDiscoveryProvider {
    private static let catalogURL = URL(string: "https://audioapi.orf.at/radiothek/api/2.0/podcasts")

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
        try await catalog(refresh: refresh).podcasts
    }

    func categories(refresh: Bool) async throws -> [PodcastDiscoveryCategory] {
        try await catalog(refresh: refresh).categories
    }

    func podcasts(in category: PodcastDiscoveryCategory, refresh: Bool) async throws -> [DiscoveredPodcast] {
        let catalog = try await catalog(refresh: refresh)
        let ids = Set(catalog.podcastIDsByStation[category.id] ?? [])
        return catalog.podcasts.filter { ids.contains($0.id) }
    }

    func search(_ query: String) async throws -> [DiscoveredPodcast] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        // The directory is a single cached document; searching it locally avoids
        // a second round trip and works while offline-cached.
        let catalog = try await catalog(refresh: false)
        return catalog.podcasts.matchingDiscoveryQuery(trimmed)
    }

    // MARK: - Catalogue

    struct Catalog: Sendable {
        let podcasts: [DiscoveredPodcast]
        let categories: [PodcastDiscoveryCategory]
        let podcastIDsByStation: [String: [String]]
    }

    private func catalog(refresh: Bool) async throws -> Catalog {
        try await cache.cached("orf.catalog", refresh: refresh) {
            guard let url = Self.catalogURL else {
                throw PodcastDiscoveryError.unavailable
            }

            let response = try await client.json(ORFPodcastListResponse.self, from: url, refresh: refresh)
            return Self.makeCatalog(from: response, providerID: id, broadcasterID: broadcaster.id)
        }
    }

    static func makeCatalog(
        from response: ORFPodcastListResponse,
        providerID: String,
        broadcasterID: String
    ) -> Catalog {
        var podcasts: [DiscoveredPodcast] = []
        var podcastIDsByStation: [String: [String]] = [:]
        var stationCounts: [String: Int] = [:]

        for (station, entries) in response.payload {
            for entry in entries where entry.isOnline != false {
                let identifier = String(entry.id)
                podcasts.append(
                    DiscoveredPodcast(
                        id: identifier,
                        title: entry.title,
                        author: entry.author,
                        summary: entry.description,
                        artworkURL: entry.image?.bestURL,
                        feedURL: entry.feedURL,
                        webpageURL: entry.link?.url,
                        language: entry.language,
                        providerID: providerID,
                        broadcasterID: broadcasterID,
                        providerReference: entry.slug,
                        episodeCount: entry.episodeCount
                    )
                )

                podcastIDsByStation[station, default: []].append(identifier)
                stationCounts[station, default: 0] += 1
            }
        }

        podcasts.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        let categories = stationCounts
            .map { station, count in
                PodcastDiscoveryCategory(
                    id: station,
                    title: ORFStation.displayName(for: station),
                    providerID: providerID,
                    artworkURL: nil,
                    podcastCount: count
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        return Catalog(
            podcasts: podcasts,
            categories: categories,
            podcastIDsByStation: podcastIDsByStation
        )
    }
}
