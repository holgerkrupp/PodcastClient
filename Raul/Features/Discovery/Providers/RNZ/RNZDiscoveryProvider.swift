//
//  RNZDiscoveryProvider.swift
//  Raul
//
//  Discovery for RNZ (New Zealand), backed by RNZ's public podcast directory.
//  RNZ publishes an ordinary RSS feed for every show, so a subscription started
//  here is an entirely ordinary Up Next podcast.
//

import Foundation

struct RNZDiscoveryProvider: PodcastDiscoveryProvider {
    let broadcaster: PublicBroadcaster
    private let client: PodcastDiscoveryHTTPClient
    private let cache: PodcastDiscoveryCache

    var id: String { broadcaster.id }

    var capabilities: PodcastDiscoveryCapabilities {
        [.allPodcasts, .search, .feedURL]
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
        try await cache.cached("rnz.catalog", refresh: refresh) {
            guard let directoryURL = RNZDirectoryParser.directoryURL else {
                throw PodcastDiscoveryError.unavailable
            }

            let markup = try await client.markup(from: directoryURL, refresh: refresh)
            let podcasts = RNZDirectoryParser.parseDirectory(
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

    func search(_ query: String) async throws -> [DiscoveredPodcast] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        let podcasts = try await allPodcasts(refresh: false)
        return podcasts.matchingDiscoveryQuery(trimmed)
    }

    func resolveFeed(for podcast: DiscoveredPodcast) async throws -> URL {
        if let feedURL = podcast.feedURL {
            return feedURL
        }

        guard let slug = podcast.providerReference,
              let showPageURL = RNZDirectoryParser.showPageURL(forSlug: slug) else {
            throw PodcastDiscoveryError.feedNotFound
        }

        let markup = try await client.markup(from: showPageURL, refresh: false)

        guard let feedURL = RNZDirectoryParser.parseFeedURL(showPageMarkup: markup) else {
            throw PodcastDiscoveryError.feedNotFound
        }

        return feedURL
    }
}
