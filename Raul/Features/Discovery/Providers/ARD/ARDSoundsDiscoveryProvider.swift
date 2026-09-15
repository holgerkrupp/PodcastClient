//
//  ARDSoundsDiscoveryProvider.swift
//  Raul
//
//  Discovery for ARD Sounds (Germany).
//
//  ARD is treated differently from the officially documented sources. It exposes
//  no RSS URL of its own, so a subscription needs the conventional feed the
//  originating ARD broadcaster publishes. That is resolved through an exact
//  title match on Apple Podcasts — deliberately strict, so an ambiguous title
//  resolves to nothing rather than to the wrong podcast, and the user is offered
//  the broadcaster's website instead.
//
//  Browsing reads `/organizations`, which returns the whole catalogue in one
//  request: every organization (BR, WDR, NDR, …), its stations and their shows.
//  Organizations become the categories, so the axis is the one ARD itself uses.
//
//  Consequences of ARD's shape, by design:
//   * Every ARD failure is contained here. Discovery, and the Add Podcast
//     screen, work unchanged when ARD is unavailable or switched off.
//   * The catalogue response carries no description, so browsed shows have none
//     until the user searches for them. Better an honest gap than a fake one.
//

import Foundation

struct ARDSoundsDiscoveryProvider: PodcastDiscoveryProvider {
    let broadcaster: PublicBroadcaster
    private let api: ARDSoundsAPI
    private let cache: PodcastDiscoveryCache
    private let appleResolver: ApplePodcastsFeedResolver

    var id: String { broadcaster.id }

    var capabilities: PodcastDiscoveryCapabilities {
        [.categories, .allPodcasts, .search, .feedURL]
    }

    init(
        broadcaster: PublicBroadcaster,
        client: PodcastDiscoveryHTTPClient = .shared,
        cache: PodcastDiscoveryCache = .shared,
        appleResolver: ApplePodcastsFeedResolver = ApplePodcastsFeedResolver(storefront: "de")
    ) {
        self.broadcaster = broadcaster
        self.api = ARDSoundsAPI(client: client)
        self.cache = cache
        self.appleResolver = appleResolver
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
        let ids = Set(catalog.podcastIDsByOrganization[category.id] ?? [])
        return catalog.podcasts.filter { ids.contains($0.id) }
    }

    func search(_ query: String) async throws -> [DiscoveredPodcast] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        let programSets = try await api.searchProgramSets(trimmed)
        return programSets.map { podcast(from: $0) }
    }

    func resolveFeed(for podcast: DiscoveredPodcast) async throws -> URL {
        if let feedURL = podcast.feedURL {
            return feedURL
        }

        guard let feedURL = await appleResolver.feedURL(
            matchingTitle: podcast.title,
            author: podcast.author
        ) else {
            throw PodcastDiscoveryError.feedNotFound
        }

        return feedURL
    }

    // MARK: - Catalogue

    struct Catalog: Sendable {
        let podcasts: [DiscoveredPodcast]
        let categories: [PodcastDiscoveryCategory]
        let podcastIDsByOrganization: [String: [String]]
    }

    private func catalog(refresh: Bool) async throws -> Catalog {
        try await cache.cached("ardsounds.catalog", refresh: refresh) {
            let organizations = try await api.organizations(refresh: refresh)
            return Self.makeCatalog(from: organizations, provider: self)
        }
    }

    static func makeCatalog(
        from organizations: [ARDOrganization],
        provider: ARDSoundsDiscoveryProvider
    ) -> Catalog {
        var podcasts: [DiscoveredPodcast] = []
        var podcastIDsByOrganization: [String: [String]] = [:]
        var categories: [PodcastDiscoveryCategory] = []
        var seenShowIDs = Set<String>()

        for organization in organizations {
            var idsForOrganization: [String] = []

            for service in organization.services {
                for show in service.shows {
                    // The same show can appear under more than one station.
                    guard seenShowIDs.insert(show.id).inserted else { continue }

                    podcasts.append(
                        provider.podcast(from: show, station: service.title ?? organization.name)
                    )
                    idsForOrganization.append(show.id)
                }
            }

            guard idsForOrganization.isEmpty == false else { continue }

            podcastIDsByOrganization[organization.id] = idsForOrganization
            categories.append(
                PodcastDiscoveryCategory(
                    id: organization.id,
                    title: organization.name,
                    providerID: provider.id,
                    artworkURL: nil,
                    podcastCount: idsForOrganization.count
                )
            )
        }

        podcasts.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        categories.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        return Catalog(
            podcasts: podcasts,
            categories: categories,
            podcastIDsByOrganization: podcastIDsByOrganization
        )
    }

    func podcast(from programSet: ARDProgramSet, station: String? = nil) -> DiscoveredPodcast {
        DiscoveredPodcast(
            id: programSet.id,
            title: programSet.title,
            author: programSet.author ?? station,
            summary: programSet.synopsis,
            artworkURL: programSet.image?.url(width: 448),
            feedURL: nil,
            webpageURL: programSet.webpageURL ?? broadcaster.website,
            language: "de",
            providerID: id,
            broadcasterID: broadcaster.id,
            providerReference: programSet.id,
            episodeCount: programSet.numberOfElements
        )
    }
}
