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
    var accessProfileID: String?
    var accessKindRawValue: String?
    var title: String?
    var author: String?
    var description: String?
    var artworkURL: String?
    var lastRefresh: Date?
    var lastEpisodeDate: Date?
    var lastEpisodeURL: String?

    init(
        feedURL: String,
        accessProfileID: String? = nil,
        accessKindRawValue: String? = nil,
        title: String? = nil,
        author: String? = nil,
        description: String? = nil,
        artworkURL: String? = nil,
        lastRefresh: Date? = nil,
        lastEpisodeDate: Date? = nil,
        lastEpisodeURL: String? = nil
    ) {
        self.feedURL = feedURL
        self.accessProfileID = accessProfileID
        self.accessKindRawValue = accessKindRawValue
        self.title = title
        self.author = author
        self.description = description
        self.artworkURL = artworkURL
        self.lastRefresh = lastRefresh
        self.lastEpisodeDate = lastEpisodeDate
        self.lastEpisodeURL = lastEpisodeURL
    }
}

enum SubscriptionManifestSync {
    private static let key = "subscriptionManifest.v1"
    /// Feeds the user deleted on this device, keyed by feed and stamped with the
    /// deletion date. Local only - the manifest itself lives in iCloud, and a
    /// copy of it that predates the deletion must not restore the podcast.
    private static let deletedFeedsKey = "subscriptionManifest.deletedFeeds.v1"
    private static let maximumRememberedDeletions = 250
    private static let deletionMemoryDuration: TimeInterval = 180 * 24 * 60 * 60
    private static let bootstrapEpisodeLimit = 25
    private static let bootstrapConcurrency = 3

    static func loadManifest() -> SubscriptionManifest? {
        let store = NSUbiquitousKeyValueStore.default
        store.synchronize()

        guard let data = store.data(forKey: key) else { return nil }
        guard let manifest = try? JSONDecoder().decode(SubscriptionManifest.self, from: data) else {
            return nil
        }

        var didSanitize = false
        let sanitizedEntries = manifest.entries.map { original -> SubscriptionManifestEntry in
            guard let legacyURL = URL(string: original.feedURL) else { return original }
            var entry = original

            if legacyURL.isLikelyPrivatePodcastURL {
                let kind: PodcastAccessKind = legacyURL.user != nil || legacyURL.password != nil
                    ? .httpBasic
                    : .privateURL
                let profile = PodcastAccessProfile.make(for: legacyURL, kind: kind)
                let credential: PodcastCredential = kind == .httpBasic
                    ? .httpBasic(username: legacyURL.user ?? "", password: legacyURL.password ?? "")
                    : .privateURL(legacyURL)
                try? KeychainPodcastCredentialStore.shared.save(credential, for: profile)
                entry.accessProfileID = profile.id
                entry.accessKindRawValue = profile.kind.rawValue
                entry.feedURL = normalizedFeedKey(legacyURL)
                if let episodeURL = entry.lastEpisodeURL.flatMap(URL.init(string:)),
                   episodeURL.isLikelyPrivatePodcastURL {
                    entry.lastEpisodeURL = nil
                }
                didSanitize = true
            }

            return entry
        }

        guard didSanitize == false else {
            var sanitizedManifest = manifest
            sanitizedManifest.entries = sanitizedEntries
            sanitizedManifest.updatedAt = Date()
            save(sanitizedManifest)
            return sanitizedManifest
        }
        return manifest
    }

    static func publishCurrentSubscriptions(
        modelContainer: ModelContainer,
        allowEmpty: Bool = false
    ) async {
        // The previously published entries carry the newest episode of every
        // feed. Handing them to the actor lets it skip the episode lookup for
        // podcasts that have not been refreshed since.
        let previousEntries = entriesByFeedKey(in: loadManifest())
        let manifest = await SubscriptionManifestModelActor(modelContainer: modelContainer)
            .makeManifest(previousEntries: previousEntries, deletedFeeds: deletedFeeds())
        guard allowEmpty || manifest.entries.isEmpty == false else { return }
        forgetDeletions(for: manifest.entries)
        save(manifest)
    }

    /// Removes a feed from the published manifest and remembers the deletion.
    ///
    /// Deleting a podcast cascades through every episode, chapter and bookmark
    /// it owns; if that work is interrupted - or the app is killed before the
    /// manifest is republished - the stale manifest would bootstrap the podcast
    /// straight back on the next launch. Dropping the entry up front is cheap
    /// and makes the deletion stick either way.
    static func forgetFeed(_ feedURL: URL) {
        rememberDeletion(of: feedURL)

        guard var manifest = loadManifest() else { return }
        let removedKey = normalizedFeedKey(feedURL)
        let remaining = manifest.entries.filter { entry in
            guard let url = URL(string: entry.feedURL) else { return true }
            return normalizedFeedKey(url) != removedKey
        }

        guard remaining.count != manifest.entries.count else { return }
        manifest.entries = remaining
        manifest.updatedAt = Date()
        save(manifest)
    }

    static func restoreSubscriptionsAndBootstrap(modelContainer: ModelContainer) async {
        guard let manifest = loadManifest(), manifest.entries.isEmpty == false else { return }

        let feedsToBootstrap = await SubscriptionManifestModelActor(modelContainer: modelContainer)
            .restore(manifest, deletedFeeds: deletedFeeds())

        guard feedsToBootstrap.isEmpty == false else { return }
        await bootstrap(feedsToBootstrap, modelContainer: modelContainer)
    }

    static func normalizedFeedKey(_ url: URL) -> String {
        PodcastFeedIdentity.normalizedFeedURLString(url)
    }

    private static func entriesByFeedKey(
        in manifest: SubscriptionManifest?
    ) -> [String: SubscriptionManifestEntry] {
        guard let manifest else { return [:] }

        return manifest.entries.reduce(into: [:]) { result, entry in
            guard let url = URL(string: entry.feedURL) else { return }
            result[normalizedFeedKey(url)] = entry
        }
    }

    private static func save(_ manifest: SubscriptionManifest) {
        guard let data = try? JSONEncoder().encode(manifest) else { return }

        let store = NSUbiquitousKeyValueStore.default
        store.set(data, forKey: key)
        store.synchronize()
    }

    // MARK: - Deleted feeds

    static func deletedFeeds() -> [String: Date] {
        let stored = UserDefaults.standard.dictionary(forKey: deletedFeedsKey) as? [String: Date]
        return stored ?? [:]
    }

    private static func rememberDeletion(of feedURL: URL) {
        let feedKey = normalizedFeedKey(feedURL)
        guard feedKey.isEmpty == false else { return }

        var deletions = deletedFeeds()
        deletions[feedKey] = Date()
        store(deletions)
    }

    /// A feed that is subscribed again - here or on another device - is no
    /// longer a deletion worth remembering.
    private static func forgetDeletions(for entries: [SubscriptionManifestEntry]) {
        var deletions = deletedFeeds()
        guard deletions.isEmpty == false else { return }

        for entry in entries {
            guard let url = URL(string: entry.feedURL) else { continue }
            deletions.removeValue(forKey: normalizedFeedKey(url))
        }

        store(deletions)
    }

    private static func store(_ deletions: [String: Date]) {
        let cutoff = Date().addingTimeInterval(-deletionMemoryDuration)
        let recent = deletions
            .filter { $0.value > cutoff }
            .sorted { $0.value > $1.value }
            .prefix(maximumRememberedDeletions)

        UserDefaults.standard.set(
            Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0.value) }),
            forKey: deletedFeedsKey
        )
    }

    private static func bootstrap(_ feeds: [URL], modelContainer: ModelContainer) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = feeds.makeIterator()

            for _ in 0..<min(bootstrapConcurrency, feeds.count) {
                guard let feed = iterator.next() else { break }
                group.addTask {
                    _ = try? await PodcastModelActor(modelContainer: modelContainer)
                        .bootstrapPodcast(feed, maximumEpisodes: bootstrapEpisodeLimit)
                }
            }

            while await group.next() != nil {
                guard let feed = iterator.next() else { continue }
                group.addTask {
                    _ =  try? await PodcastModelActor(modelContainer: modelContainer)
                        .bootstrapPodcast(feed, maximumEpisodes: bootstrapEpisodeLimit)
                }
            }
        }

        await publishCurrentSubscriptions(modelContainer: modelContainer)
    }
}

@ModelActor
actor SubscriptionManifestModelActor {
    func makeManifest(
        previousEntries: [String: SubscriptionManifestEntry] = [:],
        deletedFeeds: [String: Date] = [:]
    ) -> SubscriptionManifest {
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
            let feedKey = SubscriptionManifestSync.normalizedFeedKey(feed)
            guard feedKey.isEmpty == false else { continue }

            // A publish can overlap the delete that is still cascading through
            // the podcast's episodes. Republishing the feed in that window would
            // undo the deletion, so a podcast that has not been subscribed again
            // since it was deleted stays out of the manifest.
            if let deletedAt = deletedFeeds[feedKey],
               deletedAt > (podcast.metaData?.subscriptionDate ?? .distantPast) {
                continue
            }

            let lastRefresh = podcast.metaData?.lastRefresh
            let latest = latestEpisode(
                of: podcast,
                lastRefresh: lastRefresh,
                cachedEntry: previousEntries[feedKey]
            )
            let accessProfile = Self.accessProfile(for: feed)

            entriesByFeed[feedKey] = SubscriptionManifestEntry(
                feedURL: feedKey,
                accessProfileID: accessProfile?.id,
                accessKindRawValue: accessProfile?.kind.rawValue,
                title: podcast.title,
                author: podcast.author,
                description: podcast.desc,
                artworkURL: podcast.imageURL?.absoluteString,
                lastRefresh: lastRefresh,
                lastEpisodeDate: latest.date,
                lastEpisodeURL: latest.url
            )
        }

        return SubscriptionManifest(
            entries: entriesByFeed.values.sorted {
                ($0.title ?? $0.feedURL).localizedCaseInsensitiveCompare($1.title ?? $1.feedURL) == .orderedAscending
            }
        )
    }

    /// The newest episode of `podcast`, as plain values.
    ///
    /// Walking `podcast.episodes` here used to materialise every episode row of
    /// every subscribed podcast on each publish - and a publish runs after every
    /// refresh, subscribe and delete. Besides being the slowest part of the
    /// publish it also reads rows another context may have just deleted, which
    /// traps inside the generated property getter. Both problems go away by
    /// letting the store do the sorting and by reusing what was published last.
    private func latestEpisode(
        of podcast: Podcast,
        lastRefresh: Date?,
        cachedEntry: SubscriptionManifestEntry?
    ) -> (date: Date?, url: String?) {
        if let cachedEntry,
           cachedEntry.lastEpisodeDate != nil,
           cachedEntry.lastRefresh == lastRefresh {
            return (cachedEntry.lastEpisodeDate, cachedEntry.lastEpisodeURL)
        }

        let podcastID = podcast.persistentModelID
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { episode in
                episode.podcast?.persistentModelID == podcastID
            },
            sortBy: [SortDescriptor(\.publishDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        guard let episode = try? modelContext.fetch(descriptor).first else {
            return (nil, nil)
        }

        return (episode.publishDate, episode.url?.absoluteString)
    }

    func restore(
        _ manifest: SubscriptionManifest,
        deletedFeeds: [String: Date] = [:]
    ) -> [URL] {
        guard manifest.schemaVersion <= SubscriptionManifest.currentSchemaVersion else {
            return []
        }

        let validEntries = deduplicatedEntries(from: manifest)
        guard validEntries.isEmpty == false else { return [] }

        var feedsToBootstrap: [URL] = []
        let accessResolver = PodcastAccessResolver()

        for entry in validEntries {
            guard let manifestFeed = URL(string: entry.feedURL) else { continue }

            // A manifest written before the user deleted this feed still lists
            // it. Restoring from it would resurrect the podcast the user just
            // removed, so wait for a manifest that knows about the deletion.
            if let deletedAt = deletedFeeds[SubscriptionManifestSync.normalizedFeedKey(manifestFeed)],
               deletedAt > manifest.updatedAt {
                continue
            }

            let profile = accessProfile(for: entry, resourceURL: manifestFeed)
            let resolvedFeed = profile.flatMap {
                try? accessResolver.resolvedURL(for: $0, fallbackURL: manifestFeed)
            } ?? manifestFeed
            let hasCredential = profile.map {
                accessResolver.credentialState(for: $0) == .available
            } ?? true

            let podcast = fetchPodcast(feed: resolvedFeed) ?? {
                let podcast = Podcast(feed: resolvedFeed)
                modelContext.insert(podcast)
                if hasCredential {
                    feedsToBootstrap.append(resolvedFeed)
                }
                return podcast
            }()

            apply(
                entry,
                to: podcast,
                profile: profile,
                hasCredential: hasCredential,
                manifestUpdatedAt: manifest.updatedAt
            )

            if podcast.episodes?.isEmpty != false && hasCredential {
                feedsToBootstrap.append(resolvedFeed)
            }
        }

        modelContext.saveIfNeeded()
        return Array(Set(feedsToBootstrap)).sorted { $0.absoluteString < $1.absoluteString }
    }

    private func deduplicatedEntries(from manifest: SubscriptionManifest) -> [SubscriptionManifestEntry] {
        var entriesByFeed: [String: SubscriptionManifestEntry] = [:]

        for entry in manifest.entries {
            guard let feed = URL(string: entry.feedURL) else { continue }
            let feedKey = SubscriptionManifestSync.normalizedFeedKey(feed)
            guard feedKey.isEmpty == false else { continue }

            entriesByFeed[feedKey] = entry
        }

        return Array(entriesByFeed.values)
    }

    private func fetchPodcast(feed: URL) -> Podcast? {
        let candidates = (try? modelContext.fetch(FetchDescriptor<Podcast>())) ?? []
        return candidates.first { podcast in
            guard let existingFeed = podcast.feed else { return false }
            return existingFeed.podcastFeedComparisonKeys
                .intersection(feed.podcastFeedComparisonKeys)
                .isEmpty == false
        }
    }

    private func apply(
        _ entry: SubscriptionManifestEntry,
        to podcast: Podcast,
        profile: PodcastAccessProfile?,
        hasCredential: Bool,
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
        metaData.accessProfileID = profile?.id
        metaData.accessKindRawValue = profile?.kind.rawValue
        metaData.credentialState = hasCredential ? .available : .missing
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

    private func accessProfile(
        for entry: SubscriptionManifestEntry,
        resourceURL: URL
    ) -> PodcastAccessProfile? {
        guard let id = entry.accessProfileID,
              let rawKind = entry.accessKindRawValue,
              let kind = PodcastAccessKind(rawValue: rawKind) else {
            return nil
        }
        return PodcastAccessProfile(
            id: id,
            kind: kind,
            resourceURL: resourceURL
        )
    }

    private static func accessProfile(for feed: URL) -> PodcastAccessProfile? {
        guard feed.isLikelyPrivatePodcastURL else { return nil }
        let kind: PodcastAccessKind = feed.user != nil || feed.password != nil
            ? .httpBasic
            : .privateURL
        let profile = PodcastAccessProfile.make(for: feed, kind: kind)
        let credential: PodcastCredential
        switch kind {
        case .privateURL:
            credential = .privateURL(feed)
        case .httpBasic:
            credential = .httpBasic(username: feed.user ?? "", password: feed.password ?? "")
        case .publicFeed, .bearerToken:
            return nil
        }
        try? KeychainPodcastCredentialStore.shared.save(credential, for: profile)
        return profile
    }
}
