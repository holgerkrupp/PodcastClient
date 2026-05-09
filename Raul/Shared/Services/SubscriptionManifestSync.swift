import Foundation
import SwiftData

struct SubscriptionManifest: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: Date
    var entries: [SubscriptionManifestEntry]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        updatedAt: Date = Date(),
        entries: [SubscriptionManifestEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.entries = entries
    }
}

struct SubscriptionManifestEntry: Codable, Hashable, Sendable {
    var feedURL: String
    var title: String?
    var author: String?
    var description: String?
    var artworkURL: String?
    var lastRefresh: Date?
    var lastEpisodeDate: Date?
    var lastEpisodeURL: String?
}

enum SubscriptionManifestSync {
    private static let key = "subscriptionManifest.v1"
    private static let bootstrapEpisodeLimit = 25
    private static let bootstrapConcurrency = 3

    static func loadManifest() -> SubscriptionManifest? {
        let store = NSUbiquitousKeyValueStore.default
        store.synchronize()

        guard let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SubscriptionManifest.self, from: data)
    }

    static func publishCurrentSubscriptions(
        modelContainer: ModelContainer,
        allowEmpty: Bool = false
    ) async {
        let manifest = await SubscriptionManifestModelActor(modelContainer: modelContainer)
            .makeManifest()
        guard allowEmpty || manifest.entries.isEmpty == false else { return }
        save(manifest)
    }

    static func restoreSubscriptionsAndBootstrap(modelContainer: ModelContainer) async {
        guard let manifest = loadManifest(), manifest.entries.isEmpty == false else { return }

        let feedsToBootstrap = await SubscriptionManifestModelActor(modelContainer: modelContainer)
            .restore(manifest)

        guard feedsToBootstrap.isEmpty == false else { return }
        await bootstrap(feedsToBootstrap, modelContainer: modelContainer)
    }

    private static func save(_ manifest: SubscriptionManifest) {
        guard let data = try? JSONEncoder().encode(manifest) else { return }

        let store = NSUbiquitousKeyValueStore.default
        store.set(data, forKey: key)
        store.synchronize()
    }

    private static func bootstrap(_ feeds: [URL], modelContainer: ModelContainer) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = feeds.makeIterator()

            for _ in 0..<min(bootstrapConcurrency, feeds.count) {
                guard let feed = iterator.next() else { break }
                group.addTask {
                    try? await PodcastModelActor(modelContainer: modelContainer)
                        .bootstrapPodcast(feed, maximumEpisodes: bootstrapEpisodeLimit)
                }
            }

            while await group.next() != nil {
                guard let feed = iterator.next() else { continue }
                group.addTask {
                    try? await PodcastModelActor(modelContainer: modelContainer)
                        .bootstrapPodcast(feed, maximumEpisodes: bootstrapEpisodeLimit)
                }
            }
        }

        await publishCurrentSubscriptions(modelContainer: modelContainer)
    }
}

@ModelActor
actor SubscriptionManifestModelActor {
    func makeManifest() -> SubscriptionManifest {
        let descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { podcast in
                podcast.metaData?.isSubscribed != false
            },
            sortBy: [SortDescriptor(\.title)]
        )

        let podcasts = (try? modelContext.fetch(descriptor)) ?? []
        var entriesByFeed: [String: SubscriptionManifestEntry] = [:]

        for podcast in podcasts {
            guard let feed = podcast.feed else { continue }
            let feedKey = normalizedFeedKey(feed)
            guard feedKey.isEmpty == false else { continue }

            let latestEpisode = podcast.episodes?.max {
                ($0.publishDate ?? .distantPast) < ($1.publishDate ?? .distantPast)
            }

            entriesByFeed[feedKey] = SubscriptionManifestEntry(
                feedURL: feed.absoluteString,
                title: podcast.title,
                author: podcast.author,
                description: podcast.desc,
                artworkURL: podcast.imageURL?.absoluteString,
                lastRefresh: podcast.metaData?.lastRefresh,
                lastEpisodeDate: latestEpisode?.publishDate,
                lastEpisodeURL: latestEpisode?.url?.absoluteString
            )
        }

        return SubscriptionManifest(
            entries: entriesByFeed.values.sorted {
                ($0.title ?? $0.feedURL).localizedCaseInsensitiveCompare($1.title ?? $1.feedURL) == .orderedAscending
            }
        )
    }

    func restore(_ manifest: SubscriptionManifest) -> [URL] {
        guard manifest.schemaVersion <= SubscriptionManifest.currentSchemaVersion else {
            return []
        }

        let validEntries = deduplicatedEntries(from: manifest)
        guard validEntries.isEmpty == false else { return [] }

        var feedsToBootstrap: [URL] = []

        for entry in validEntries {
            guard let feed = URL(string: entry.feedURL) else { continue }

            let podcast = fetchPodcast(feed: feed) ?? {
                let podcast = Podcast(feed: feed)
                modelContext.insert(podcast)
                feedsToBootstrap.append(feed)
                return podcast
            }()

            apply(entry, to: podcast, manifestUpdatedAt: manifest.updatedAt)

            if podcast.episodes?.isEmpty != false {
                feedsToBootstrap.append(feed)
            }
        }

        modelContext.saveIfNeeded()
        return Array(Set(feedsToBootstrap)).sorted { $0.absoluteString < $1.absoluteString }
    }

    private func deduplicatedEntries(from manifest: SubscriptionManifest) -> [SubscriptionManifestEntry] {
        var entriesByFeed: [String: SubscriptionManifestEntry] = [:]

        for entry in manifest.entries {
            guard let feed = URL(string: entry.feedURL) else { continue }
            let feedKey = normalizedFeedKey(feed)
            guard feedKey.isEmpty == false else { continue }

            entriesByFeed[feedKey] = entry
        }

        return Array(entriesByFeed.values)
    }

    private func fetchPodcast(feed: URL) -> Podcast? {
        let descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { podcast in
                podcast.feed == feed
            }
        )

        return try? modelContext.fetch(descriptor).first
    }

    private func apply(
        _ entry: SubscriptionManifestEntry,
        to podcast: Podcast,
        manifestUpdatedAt: Date
    ) {
        if podcast.title == "Loading..." || podcast.title == podcast.feed?.absoluteString {
            podcast.title = nonEmpty(entry.title) ?? podcast.title
        }

        if podcast.author == nil {
            podcast.author = nonEmpty(entry.author)
        }

        if podcast.desc == nil {
            podcast.desc = nonEmpty(entry.description)
        }

        if podcast.imageURL == nil,
           let artworkURL = entry.artworkURL.flatMap(URL.init(string:)) {
            podcast.imageURL = artworkURL
        }

        let metaData = ensureMetadata(for: podcast)
        metaData.isSubscribed = true
        metaData.subscriptionDate = metaData.subscriptionDate ?? manifestUpdatedAt
        metaData.lastRefresh = metaData.lastRefresh ?? entry.lastRefresh
    }

    private func ensureMetadata(for podcast: Podcast) -> PodcastMetaData {
        if let metaData = podcast.metaData {
            return metaData
        }

        let metaData = PodcastMetaData()
        modelContext.insert(metaData)
        podcast.metaData = metaData
        return metaData
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else {
            return nil
        }

        return value
    }

    private func normalizedFeedKey(_ url: URL) -> String {
        url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
