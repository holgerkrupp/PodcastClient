//
//  RTPDiscoveryProvider.swift
//  Raul
//
//  Discovery for RTP (Portugal), backed by RTP Play's public podcast directory.
//
//  RTP's directory is server-rendered HTML and does not carry RSS URLs, so feed
//  resolution is a second step: open the show page and follow the Apple Podcasts
//  link RTP itself publishes there. That is an exact pointer, not a guess, and
//  it fails cleanly when a show has no public feed.
//

import Foundation

struct RTPDiscoveryProvider: PodcastDiscoveryProvider {
    let broadcaster: PublicBroadcaster
    private let client: PodcastDiscoveryHTTPClient
    private let cache: PodcastDiscoveryCache
    private let appleResolver: ApplePodcastsFeedResolver

    var id: String { broadcaster.id }

    var capabilities: PodcastDiscoveryCapabilities {
        [.allPodcasts, .search, .feedURL]
    }

    /// RTP's directory is noticeably slower than the other sources, so it gets
    /// a longer timeout than the shared default rather than failing spuriously.
    static let defaultClient = PodcastDiscoveryHTTPClient(timeout: 35)

    init(
        broadcaster: PublicBroadcaster,
        client: PodcastDiscoveryHTTPClient = RTPDiscoveryProvider.defaultClient,
        cache: PodcastDiscoveryCache = .shared,
        appleResolver: ApplePodcastsFeedResolver = ApplePodcastsFeedResolver(storefront: "pt")
    ) {
        self.broadcaster = broadcaster
        self.client = client
        self.cache = cache
        self.appleResolver = appleResolver
    }

    func allPodcasts(refresh: Bool) async throws -> [DiscoveredPodcast] {
        try await cache.cached("rtp.catalog", refresh: refresh) {
            guard let directoryURL = RTPDirectoryParser.directoryURL else {
                throw PodcastDiscoveryError.unavailable
            }

            let markup = try await client.markup(from: directoryURL, refresh: refresh)
            let podcasts = RTPDirectoryParser.parseDirectory(
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

        guard let showPageURL = podcast.webpageURL else {
            throw PodcastDiscoveryError.feedNotFound
        }

        let markup = try await client.markup(from: showPageURL, refresh: false)

        if let direct = RTPDirectoryParser.parseDirectFeedURL(showPageMarkup: markup) {
            return direct
        }

        guard let collectionID = ApplePodcastsFeedResolver.appleCollectionID(inMarkup: markup),
              let feedURL = await appleResolver.feedURL(forAppleCollectionID: collectionID) else {
            throw PodcastDiscoveryError.feedNotFound
        }

        return feedURL
    }
}
