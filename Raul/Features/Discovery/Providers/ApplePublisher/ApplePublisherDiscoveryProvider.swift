//
//  ApplePublisherDiscoveryProvider.swift
//  Raul
//
//  Discovery for broadcasters that publish ordinary podcast feeds but offer no
//  machine-readable directory of their own. Their shows are found in the Apple
//  Podcasts catalogue, filtered to the broadcaster's own publisher names.
//
//  This is deliberately a different kind of source from the other providers, and
//  it says so: every screen backed by it carries an attribution line, because
//  the data does not come from the broadcaster. What it returns is real — each
//  result carries the broadcaster's own RSS feed, so subscribing works exactly
//  as it does everywhere else — but the selection is only as complete as Apple's
//  catalogue and its result limit allow.
//
//  Publisher matching is explicit per broadcaster rather than a fuzzy name test,
//  because publisher names collide across broadcasters ("ABC News" is both an
//  Australian and an American publisher). A broadcaster whose shows cannot be
//  told apart safely is not offered at all.
//

import Foundation

/// How one broadcaster's shows are recognised in the Apple catalogue.
struct ApplePublisherRule: Sendable {
    /// Storefront to query, e.g. "gb".
    let storefront: String
    /// Search terms. Apple's result list is capped and relevance-ranked, so
    /// several narrow terms find more than one broad one.
    let queries: [String]
    /// Publisher names that identify this broadcaster exactly.
    let exactPublishers: [String]
    /// Publisher name prefixes, for broadcasters whose imprints all share one
    /// distinctive stem ("BBC Radio 4", "BBC World Service", …).
    let publisherPrefixes: [String]

    init(
        storefront: String,
        queries: [String],
        exactPublishers: [String] = [],
        publisherPrefixes: [String] = []
    ) {
        self.storefront = storefront
        self.queries = queries
        self.exactPublishers = exactPublishers
        self.publisherPrefixes = publisherPrefixes
    }

    func matches(publisher: String?) -> Bool {
        guard let publisher, publisher.isEmpty == false else { return false }
        let key = publisher.discoveryComparisonKey
        guard key.isEmpty == false else { return false }

        if exactPublishers.contains(where: { $0.discoveryComparisonKey == key }) {
            return true
        }

        return publisherPrefixes.contains { prefix in
            let prefixKey = prefix.discoveryComparisonKey
            return prefixKey.isEmpty == false && key.hasPrefix(prefixKey)
        }
    }
}

struct ApplePublisherDiscoveryProvider: PodcastDiscoveryProvider {
    let broadcaster: PublicBroadcaster
    let rule: ApplePublisherRule
    private let cache: PodcastDiscoveryCache
    private let searchLimit: Int

    var id: String { broadcaster.id }

    var capabilities: PodcastDiscoveryCapabilities {
        [.publisherCatalog, .search, .feedURL]
    }

    var attribution: LocalizedStringResource? {
        LocalizedStringResource("Found in the Apple Podcasts catalogue.")
    }

    init(
        broadcaster: PublicBroadcaster,
        rule: ApplePublisherRule,
        cache: PodcastDiscoveryCache = .shared,
        searchLimit: Int = 200
    ) {
        self.broadcaster = broadcaster
        self.rule = rule
        self.cache = cache
        self.searchLimit = searchLimit
    }

    func allPodcasts(refresh: Bool) async throws -> [DiscoveredPodcast] {
        try await cache.cached("applepublisher.\(id)", refresh: refresh) {
            let feeds = await fetchFeeds()
            let podcasts = Self.podcasts(
                from: feeds,
                rule: rule,
                providerID: id,
                broadcasterID: broadcaster.id
            )

            guard podcasts.isEmpty == false else {
                throw PodcastDiscoveryError.unavailable
            }

            return podcasts
        }
    }

    func search(_ query: String) async throws -> [DiscoveredPodcast] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        // Searching the cached, publisher-filtered selection keeps results
        // inside this broadcaster instead of drifting into the wider catalogue.
        let podcasts = try await allPodcasts(refresh: false)
        return podcasts.matchingDiscoveryQuery(trimmed)
    }

    /// Runs the rule's queries concurrently against the app's existing Apple
    /// Podcasts client. A query that returns nothing simply contributes nothing.
    private func fetchFeeds() async -> [PodcastFeed] {
        let storefront = rule.storefront
        let limit = searchLimit

        return await withTaskGroup(of: [PodcastFeed].self) { group in
            for query in rule.queries {
                group.addTask {
                    await ITunesSearchActor(country: storefront).search(for: query, limit: limit) ?? []
                }
            }

            var collected: [PodcastFeed] = []
            for await feeds in group {
                collected.append(contentsOf: feeds)
            }
            return collected
        }
    }

    static func podcasts(
        from feeds: [PodcastFeed],
        rule: ApplePublisherRule,
        providerID: String,
        broadcasterID: String
    ) -> [DiscoveredPodcast] {
        var seenFeeds = Set<String>()
        var results: [DiscoveredPodcast] = []

        for feed in feeds {
            guard let feedURL = feed.url,
                  let title = feed.title, title.isEmpty == false,
                  rule.matches(publisher: feed.artist),
                  seenFeeds.insert(DiscoveredPodcast.normalizedFeedKey(feedURL)).inserted else {
                continue
            }

            results.append(
                DiscoveredPodcast(
                    id: DiscoveredPodcast.normalizedFeedKey(feedURL),
                    title: title,
                    author: feed.artist,
                    summary: feed.description,
                    artworkURL: feed.artworkURL,
                    feedURL: feedURL,
                    webpageURL: feed.link,
                    language: nil,
                    providerID: providerID,
                    broadcasterID: broadcasterID,
                    providerReference: nil
                )
            )
        }

        return results.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
