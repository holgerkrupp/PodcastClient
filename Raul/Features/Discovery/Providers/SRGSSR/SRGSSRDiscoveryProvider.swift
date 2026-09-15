//
//  SRGSSRDiscoveryProvider.swift
//  Raul
//
//  Discovery for one SRG SSR business unit (SRF, RTS, RSI or RTR), backed by the
//  official Integration Layer API.
//
//  Categories are not a separate endpoint: every show carries its topics, so the
//  cached alphabetical catalogue is grouped locally instead of fetching twice.
//
//  Not every SRG radio show is published as a podcast. Shows that are not are
//  left out of the catalogue rather than listed as dead ends. SRF publishes an
//  RSS URL directly; RTS publishes a show page that advertises the feed, so RTS
//  needs one more hop during feed resolution.
//

import Foundation

struct SRGSSRDiscoveryProvider: PodcastDiscoveryProvider {
    let businessUnit: SRGSSRBusinessUnit
    let broadcaster: PublicBroadcaster
    private let api: SRGSSRAPI
    private let client: PodcastDiscoveryHTTPClient
    private let cache: PodcastDiscoveryCache

    var id: String { broadcaster.id }

    var capabilities: PodcastDiscoveryCapabilities {
        [.categories, .allPodcasts, .search, .feedURL]
    }

    init(
        businessUnit: SRGSSRBusinessUnit,
        broadcaster: PublicBroadcaster,
        client: PodcastDiscoveryHTTPClient = .shared,
        cache: PodcastDiscoveryCache = .shared
    ) {
        self.businessUnit = businessUnit
        self.broadcaster = broadcaster
        self.api = SRGSSRAPI(businessUnit: businessUnit, client: client)
        self.client = client
        self.cache = cache
    }

    // MARK: - Browsing

    func allPodcasts(refresh: Bool) async throws -> [DiscoveredPodcast] {
        try await catalog(refresh: refresh).podcasts
    }

    func categories(refresh: Bool) async throws -> [PodcastDiscoveryCategory] {
        try await catalog(refresh: refresh).categories
    }

    func podcasts(in category: PodcastDiscoveryCategory, refresh: Bool) async throws -> [DiscoveredPodcast] {
        let catalog = try await catalog(refresh: refresh)
        let ids = catalog.podcastIDsByTopicID[category.id] ?? []
        let wanted = Set(ids)
        return catalog.podcasts.filter { wanted.contains($0.id) }
    }

    func search(_ query: String) async throws -> [DiscoveredPodcast] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        let shows = try await api.searchShows(trimmed)
        return shows.map(podcast(from:))
    }

    // MARK: - Feed resolution

    func resolveFeed(for podcast: DiscoveredPodcast) async throws -> URL {
        if let feedURL = podcast.feedURL {
            return feedURL
        }

        // Search results carry no feed; the show endpoint does.
        guard let showID = podcast.providerReference else {
            throw PodcastDiscoveryError.feedNotFound
        }

        let show = try await api.show(id: showID)

        if let feedURL = show.feedURL {
            return feedURL
        }

        guard let subscriptionURL = show.podcastSubscriptionUrl else {
            throw PodcastDiscoveryError.feedNotFound
        }

        return try await feedURL(advertisedOn: subscriptionURL)
    }

    /// Reads the feed a show page advertises, using the app's existing
    /// `<link rel="alternate">` discovery rather than a second implementation.
    private func feedURL(advertisedOn pageURL: URL) async throws -> URL {
        let markup = try await client.markup(from: pageURL, refresh: false)

        guard let feedURL = PodcastFeedResolver.extractFeedURL(fromHTML: markup, baseURL: pageURL) else {
            throw PodcastDiscoveryError.feedNotFound
        }

        return feedURL
    }

    // MARK: - Catalogue

    struct Catalog: Sendable {
        let podcasts: [DiscoveredPodcast]
        let categories: [PodcastDiscoveryCategory]
        let podcastIDsByTopicID: [String: [String]]
    }

    private var cacheKey: String { "srgssr.catalog.\(businessUnit.rawValue)" }

    private func catalog(refresh: Bool) async throws -> Catalog {
        try await cache.cached(cacheKey, refresh: refresh) {
            let shows = try await api.alphabeticalShows(refresh: refresh)
            return Self.makeCatalog(from: shows.filter(\.isSubscribable), provider: self)
        }
    }

    static func makeCatalog(from shows: [SRGSSRShow], provider: SRGSSRDiscoveryProvider) -> Catalog {
        var podcastIDsByTopicID: [String: [String]] = [:]
        var topicTitles: [String: String] = [:]
        var topicArtwork: [String: URL] = [:]

        let podcasts = shows.map { show -> DiscoveredPodcast in
            for topic in show.topicList ?? [] {
                podcastIDsByTopicID[topic.id, default: []].append(show.id)
                topicTitles[topic.id] = topic.title
                if let imageUrl = topic.imageUrl {
                    topicArtwork[topic.id] = imageUrl
                }
            }
            return provider.podcast(from: show)
        }

        let categories = topicTitles
            .map { id, title in
                PodcastDiscoveryCategory(
                    id: id,
                    title: title,
                    providerID: provider.id,
                    artworkURL: topicArtwork[id],
                    podcastCount: podcastIDsByTopicID[id]?.count
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        return Catalog(
            podcasts: podcasts,
            categories: categories,
            podcastIDsByTopicID: podcastIDsByTopicID
        )
    }

    func podcast(from show: SRGSSRShow) -> DiscoveredPodcast {
        DiscoveredPodcast(
            id: show.id,
            title: show.title,
            author: broadcaster.name,
            summary: show.summary,
            artworkURL: show.artworkURL,
            feedURL: show.feedURL,
            webpageURL: show.podcastSubscriptionUrl ?? broadcaster.website,
            language: businessUnit.languageCode,
            providerID: id,
            broadcasterID: broadcaster.id,
            providerReference: show.id,
            episodeCount: show.numberOfEpisodes
        )
    }
}
