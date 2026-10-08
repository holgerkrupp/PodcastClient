import Foundation
import SwiftData

/// Builds one lookup for a discovery screen instead of making every result
/// row query and walk the subscription library independently.
struct PodcastDiscoverySubscriptionLookup {
    private let podcasts: [Podcast]
    private let feedMatches: [String: [Int]]
    private let webMatches: [String: [Int]]
    private let titleMatches: [String: [Int]]

    static func signature(for podcast: Podcast) -> String {
        let feedKeys = ([podcast.feed].compactMap { $0 } + podcast.alternativeFeeds.map(\.url))
            .flatMap(\.podcastFeedComparisonKeys)
            .sorted()
        let webKeys = podcast.link?.podcastWebComparisonKeys.sorted() ?? []
        let titleKey = podcast.title.podcastTitleComparisonKey ?? ""
        return ([String(describing: podcast.persistentModelID), titleKey] + feedKeys + webKeys)
            .joined(separator: "\u{1F}")
    }

    init(podcasts: [Podcast]) {
        let signpostID = PodcastDiscoverySignposts.begin("Discovery Subscription Index")
        defer { PodcastDiscoverySignposts.end("Discovery Subscription Index", id: signpostID, count: podcasts.count) }
        var feedMatches: [String: [Int]] = [:]
        var webMatches: [String: [Int]] = [:]
        var titleMatches: [String: [Int]] = [:]

        for (index, podcast) in podcasts.enumerated() {
            for url in ([podcast.feed].compactMap { $0 } + podcast.alternativeFeeds.map(\.url)) {
                for key in url.podcastFeedComparisonKeys {
                    feedMatches[key, default: []].append(index)
                }
            }
            if let link = podcast.link {
                for key in link.podcastWebComparisonKeys {
                    webMatches[key, default: []].append(index)
                }
            }
            if let key = podcast.title.podcastTitleComparisonKey {
                titleMatches[key, default: []].append(index)
            }
        }

        self.podcasts = podcasts
        self.feedMatches = feedMatches
        self.webMatches = webMatches
        self.titleMatches = titleMatches
    }

    func existingPodcast(for feed: PodcastFeed, context: ModelContext) -> Podcast? {
        var candidates = Set<Int>()

        func addFeedCandidates(for url: URL?) {
            guard let url else { return }
            for key in url.podcastFeedComparisonKeys {
                candidates.formUnion(feedMatches[key] ?? [])
            }
        }

        func addWebCandidates(for url: URL?) {
            guard let url else { return }
            for key in url.podcastWebComparisonKeys {
                candidates.formUnion(webMatches[key] ?? [])
            }
        }

        addFeedCandidates(for: feed.url)
        feed.alternativeFeeds.forEach { addFeedCandidates(for: $0.url) }
        addWebCandidates(for: feed.link)
        if let titleKey = feed.title?.podcastTitleComparisonKey {
            candidates.formUnion(titleMatches[titleKey] ?? [])
        }
        // Preserve the existing first-match behavior when title or identity
        // matches are ambiguous. The source array is in SwiftData query order.
        for index in candidates.sorted() where feed.matchesExistingPodcast(podcasts[index]) {
            return podcasts[index]
        }

        // Last-episode identity is deliberately a targeted slow path. Do not
        // fault every podcast's episode relationship while building the index.
        if let importedEpisodeURL = feed.importedLastEpisodeURL {
            let descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate { $0.url == importedEpisodeURL }
            )
            if let episode = try? context.fetch(descriptor).first {
                return episode.podcast
            }
        }
        return nil
    }
}

/// Process-local cache for public Apple Podcasts discovery data. Personal RSS
/// URLs and credentials never enter this cache.
actor PodcastDiscoveryCatalogCache {
    static let shared = PodcastDiscoveryCatalogCache()

    private struct Entry<Value> {
        let value: Value
        let expiresAt: Date
    }

    private var feedEntries: [String: Entry<[PodcastFeed]>] = [:]
    private var feedTasks: [String: Task<[PodcastFeed], Never>] = [:]
    private var genreEntries: [String: Entry<[AppleGenre]>] = [:]
    private var genreTasks: [String: Task<[AppleGenre], Never>] = [:]

    func feeds(
        for key: String,
        ttl: TimeInterval,
        load: @escaping @Sendable () async -> [PodcastFeed]
    ) async -> [PodcastFeed] {
        if let entry = feedEntries[key], entry.expiresAt > .now {
            return entry.value
        }
        let task: Task<[PodcastFeed], Never>
        if let inFlight = feedTasks[key] {
            task = inFlight
        } else {
            task = Task { await load() }
            feedTasks[key] = task
        }

        let value = await task.value
        feedTasks[key] = nil
        let isPublicCatalogData = value.allSatisfy {
            $0.accessCredential == nil && $0.url?.isLikelyPrivatePodcastURL != true
        }
        if value.isEmpty == false, isPublicCatalogData {
            feedEntries[key] = Entry(value: value, expiresAt: .now.addingTimeInterval(ttl))
        }
        return value
    }

    func genres(
        for key: String,
        ttl: TimeInterval,
        load: @escaping @Sendable () async -> [AppleGenre]
    ) async -> [AppleGenre] {
        if let entry = genreEntries[key], entry.expiresAt > .now {
            return entry.value
        }
        let task: Task<[AppleGenre], Never>
        if let inFlight = genreTasks[key] {
            task = inFlight
        } else {
            task = Task { await load() }
            genreTasks[key] = task
        }

        let value = await task.value
        genreTasks[key] = nil
        if value.isEmpty == false {
            genreEntries[key] = Entry(value: value, expiresAt: .now.addingTimeInterval(ttl))
        }
        return value
    }
}
