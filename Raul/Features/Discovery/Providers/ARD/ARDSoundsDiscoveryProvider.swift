//
//  ARDSoundsDiscoveryProvider.swift
//  Raul
//
//  Discovery for ARD Sounds (Germany).
//
//  ARD does not promise a general-purpose RSS feed. Resolution therefore checks
//  optional publisher metadata and official programme links before falling back
//  to a publisher-verified Apple result and, as a final RSS source, the hosted
//  ARD Sounds feed generator. Every candidate must parse as a feed and retain
//  the programme's full identity.
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
import os

private struct ARDPublicFeedValidationTransport: PodcastHTTPTransport {
    private static let maximumFeedBytes = 12 * 1024 * 1024

    func data(
        for request: URLRequest,
        profile: PodcastAccessProfile?,
        resolver: PodcastAccessResolver
    ) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              ARDSoundsDiscoveryProvider.publicHTTPURL(url.absoluteString) != nil,
              url.isLikelyPrivatePodcastURL == false else {
            throw PodcastHTTPError.invalidResponse(request.url ?? URL(string: "https://invalid.invalid")!)
        }

        var safeRequest = request
        safeRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        safeRequest.setValue(nil, forHTTPHeaderField: "Cookie")
        let delegate = ARDPublicRedirectDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await podcastURLSessionData(for: safeRequest, using: session)
        guard data.count <= Self.maximumFeedBytes,
              let finalURL = response.url,
              ARDSoundsDiscoveryProvider.publicHTTPURL(finalURL.absoluteString) != nil,
              finalURL.isLikelyPrivatePodcastURL == false else {
            throw PodcastHTTPError.invalidResponse(response.url ?? url)
        }
        return (data, response)
    }
}

private final class ARDPublicRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              ARDSoundsDiscoveryProvider.publicHTTPURL(url.absoluteString) != nil,
              url.isLikelyPrivatePodcastURL == false else {
            completionHandler(nil)
            return
        }
        var safeRequest = request
        safeRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        safeRequest.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(safeRequest)
    }
}

struct ARDSoundsDiscoveryProvider: PodcastDiscoveryProvider {
    let broadcaster: PublicBroadcaster
    private let api: ARDSoundsAPI
    private let cache: PodcastDiscoveryCache
    private let appleResolver: ApplePodcastsFeedResolver
    private let feedClient: PodcastHTTPClient

    private static let resolutionLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "UpNext",
        category: "PodcastDiscovery.ARD"
    )

    private struct CachedFeedResolution: Sendable {
        let url: URL
    }

    var id: String { broadcaster.id }

    var capabilities: PodcastDiscoveryCapabilities {
        [.categories, .allPodcasts, .search, .feedURL]
    }

    init(
        broadcaster: PublicBroadcaster,
        client: PodcastDiscoveryHTTPClient = .shared,
        cache: PodcastDiscoveryCache = .shared,
        appleResolver: ApplePodcastsFeedResolver = ApplePodcastsFeedResolver(storefront: "de"),
        feedClient: PodcastHTTPClient? = nil
    ) {
        self.broadcaster = broadcaster
        self.api = ARDSoundsAPI(client: client)
        self.cache = cache
        self.appleResolver = appleResolver
        self.feedClient = feedClient ?? PodcastHTTPClient(transport: ARDPublicFeedValidationTransport())
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
            return try await validated(feedURL, for: podcast)
        }

        let cacheKey = "ardsounds.resolved-feed.\(podcast.id)"
        if let cached: CachedFeedResolution = await cache.value(for: cacheKey) {
            return cached.url
        }

        let startedAt = ContinuousClock.now
        var sourceWasReachable = false

        // ARD's detail field is optional and currently often carries a CRID,
        // not an RSS URL. Only HTTP(S) candidates reach the existing feed
        // parser; schema changes and opaque identifiers fall through safely.
        if let programSet = try? await api.programSet(
            id: podcast.providerReference ?? podcast.id,
            fallbackNumericID: podcast.id
        ) {
            sourceWasReachable = true
            if let rawURL = programSet.feedUrl,
               let candidate = Self.publicHTTPURL(rawURL),
               let feedURL = try? await validated(candidate, for: podcast) {
                await cache.store(CachedFeedResolution(url: feedURL), for: cacheKey, lifetime: 30 * 60)
                Self.logResolution(podcast, stage: "api-feed", result: "resolved", startedAt: startedAt)
                return feedURL
            }
        }

        try Task.checkCancellation()

        // Prefer the publisher's own site, then the ARD programme page. Both
        // may advertise RSS or link directly to an Apple collection.
        let publisherPages = [podcast.publisherWebsiteURL, podcast.webpageURL]
            .compactMap { $0 }
            .filter { Self.publicHTTPURL($0.absoluteString) != nil }
        var seenPageURLs = Set<String>()
        for pageURL in publisherPages where seenPageURLs.insert(pageURL.absoluteString).inserted {
            let pageMarkup: String?
            do {
                pageMarkup = try await api.client.markup(from: pageURL)
                sourceWasReachable = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                pageMarkup = nil
            }

            if let pageMarkup,
               let htmlFeedURL = PodcastFeedResolver.extractFeedURL(fromHTML: pageMarkup, baseURL: pageURL),
               let safeFeedURL = Self.publicHTTPURL(htmlFeedURL.absoluteString),
               let feedURL = try? await validated(safeFeedURL, for: podcast) {
                await cache.store(CachedFeedResolution(url: feedURL), for: cacheKey, lifetime: 30 * 60)
                Self.logResolution(podcast, stage: "official-page-feed", result: "resolved", startedAt: startedAt)
                return feedURL
            }

            try Task.checkCancellation()

            if let pageMarkup,
               let collectionID = ApplePodcastsFeedResolver.appleCollectionID(inMarkup: pageMarkup),
               let candidate = await appleResolver.feedURL(forAppleCollectionID: collectionID),
               let feedURL = try? await validated(candidate, for: podcast) {
                await cache.store(CachedFeedResolution(url: feedURL), for: cacheKey, lifetime: 30 * 60)
                Self.logResolution(podcast, stage: "apple-link", result: "resolved", startedAt: startedAt)
                return feedURL
            }
        }

        try Task.checkCancellation()

        if let feedURL = await appleResolver.feedURL(
            matchingTitle: podcast.title,
            author: podcast.author
        ), let validatedURL = try? await validated(feedURL, for: podcast) {
            await cache.store(CachedFeedResolution(url: validatedURL), for: cacheKey, lifetime: 30 * 60)
            Self.logResolution(podcast, stage: "apple-title", result: "resolved", startedAt: startedAt)
            return validatedURL
        }

        try Task.checkCancellation()

        // Some current ARD programmes have no publisher RSS feed. The
        // community-hosted generator exposes ARD programme sets as ordinary
        // RSS. Keep it last so publisher feeds remain authoritative, and only
        // construct a URL from a verified ARD show URN (never a numeric ID or
        // an episode URN). Its output goes through the same parser and identity
        // checks as every other candidate and is otherwise invisible to users.
        if let candidate = Self.generatedRSSURL(for: podcast),
           let feedURL = try? await validated(candidate, for: podcast) {
            await cache.store(CachedFeedResolution(url: feedURL), for: cacheKey, lifetime: 30 * 60)
            Self.logResolution(podcast, stage: "generated-rss", result: "resolved", startedAt: startedAt)
            return feedURL
        }

        try Task.checkCancellation()
        let failure: PodcastDiscoveryError = sourceWasReachable ? .feedNotFound : .unavailable
        Self.logResolution(
            podcast,
            stage: "all-sources",
            result: sourceWasReachable ? "not-found" : "unreachable",
            startedAt: startedAt
        )
        throw failure
    }

    private func validated(_ candidate: URL, for podcast: DiscoveredPodcast) async throws -> URL {
        guard Self.publicHTTPURL(candidate.absoluteString) != nil else {
            throw PodcastDiscoveryError.feedNotFound
        }
        let feed = try await PodcastFeedResolver.resolveExistingEndpoint(
            from: candidate,
            allowHTMLDiscovery: true,
            client: feedClient
        )
        guard ApplePodcastsFeedResolver.title(feed.title, preserves: podcast.title) else {
            throw PodcastDiscoveryError.feedNotFound
        }
        if let expectedAuthor = podcast.author,
           let feedAuthor = feed.artist,
           ApplePodcastsFeedResolver.publisherMatches(feedAuthor, expected: expectedAuthor) == false {
            throw PodcastDiscoveryError.feedNotFound
        }
        guard let resolvedURL = feed.url,
              Self.publicHTTPURL(resolvedURL.absoluteString) != nil else {
            throw PodcastDiscoveryError.feedNotFound
        }
        return resolvedURL
    }

    static func publicHTTPURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let rawHost = url.host?.lowercased(), rawHost.isEmpty == false,
              url.user == nil, url.password == nil,
              url.isLikelyPrivatePodcastURL == false else { return nil }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard host.contains("."),
              host != "localhost",
              host.hasSuffix(".localhost") == false,
              host.hasSuffix(".local") == false,
              host.hasSuffix(".internal") == false,
              host.hasSuffix(".lan") == false,
              host.hasSuffix(".test") == false,
              host.hasSuffix(".invalid") == false,
              host.contains(":") == false else { return nil }

        let labels = host.split(separator: ".")
        // Reject IPv4 literals and non-standard numeric host encodings. This
        // prevents discovery metadata from turning feed validation into a
        // request to loopback, private, link-local, or reserved addresses.
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) {
            let octets = labels.compactMap { UInt8($0) }
            guard octets.count == 4,
                  octets[0] != 0, octets[0] != 10,
                  octets[0] != 127, octets[0] < 224,
                  !(octets[0] == 169 && octets[1] == 254),
                  !(octets[0] == 172 && (16...31).contains(octets[1])),
                  !(octets[0] == 192 && octets[1] == 168),
                  !(octets[0] == 100 && (64...127).contains(octets[1])),
                  !(octets[0] == 192 && octets[1] == 0 && octets[2] == 0),
                  !(octets[0] == 192 && octets[1] == 0 && octets[2] == 2),
                  !(octets[0] == 198 && (octets[1] == 18 || octets[1] == 19)),
                  !(octets[0] == 198 && octets[1] == 51 && octets[2] == 100),
                  !(octets[0] == 203 && octets[1] == 0 && octets[2] == 113) else { return nil }
        } else if labels.allSatisfy({ UInt64($0) != nil }) {
            return nil
        }
        return url
    }

    static func generatedRSSURL(for podcast: DiscoveredPodcast) -> URL? {
        let referenceURN = podcast.providerReference.flatMap(Self.validShowURN)
        let webpageURN = podcast.webpageURL
            .flatMap(ARDSoundsAPI.itemURN(in:))
            .flatMap(Self.validShowURN)
        guard let showURN = referenceURN ?? webpageURN else { return nil }
        var components = URLComponents(string: "https://ardsounds.tisba.de/show/\(showURN)")
        components?.scheme = "https"
        components?.host = "ardsounds.tisba.de"
        guard let url = components?.url,
              url.path == "/show/\(showURN)" else { return nil }
        return url
    }

    private static func validShowURN(_ value: String) -> String? {
        let pattern = #"^urn:ard:show:[a-f0-9]+$"#
        guard value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        return value
    }

    private static func logResolution(
        _ podcast: DiscoveredPodcast,
        stage: String,
        result: String,
        startedAt: ContinuousClock.Instant
    ) {
        let elapsed = startedAt.duration(to: .now).components
        let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        resolutionLog.info("ARD feed resolution id=\(podcast.id, privacy: .public) stage=\(stage, privacy: .public) result=\(result, privacy: .public) duration_ms=\(milliseconds, privacy: .public)")
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
            publisherWebsiteURL: programSet.publicationService?.websiteURL,
            language: "de",
            providerID: id,
            broadcasterID: broadcaster.id,
            providerReference: programSet.webpageURL.flatMap(ARDSoundsAPI.itemURN(in:)) ?? programSet.id,
            episodeCount: programSet.numberOfElements
        )
    }
}
