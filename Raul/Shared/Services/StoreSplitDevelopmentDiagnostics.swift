#if DEBUG
import Foundation
import SwiftData

struct StoreSplitDevelopmentStoreCounts: Sendable {
    var subscriptions = 0
    var episodeStates = 0
    var playlists = 0
    var playlistEntries = 0
    var queueEntries = 0
    var bookmarks = 0
    var listeningSessions = 0

    var summary: String {
        "subscriptions \(subscriptions), states \(episodeStates), playlists \(playlists), entries \(playlistEntries), queue \(queueEntries), bookmarks \(bookmarks), history \(listeningSessions)"
    }

    static func read(from container: ModelContainer) -> Self {
        let context = ModelContext(container)
        return Self(
            subscriptions: count(SubscriptionSync.self, in: context),
            episodeStates: count(EpisodeStateSync.self, in: context),
            playlists: count(PlaylistSync.self, in: context),
            playlistEntries: count(PlaylistEntrySync.self, in: context),
            queueEntries: count(QueueEntrySync.self, in: context),
            bookmarks: count(BookmarkSync.self, in: context),
            listeningSessions: count(ListeningHistorySync.self, in: context)
        )
    }

    private static func count<Model: PersistentModel>(
        _ type: Model.Type,
        in context: ModelContext
    ) -> Int {
        (try? context.fetchCount(FetchDescriptor<Model>())) ?? 0
    }
}

struct StoreSplitDevelopmentObjectCount: Identifiable, Sendable {
    let name: String
    let count: Int?

    var id: String { name }

    var displayValue: String {
        count.map(String.init) ?? "—"
    }
}

struct StoreSplitDevelopmentDatabaseCounts: Identifiable, Sendable {
    let storeName: String
    let objects: [StoreSplitDevelopmentObjectCount]
    let isAvailable: Bool

    var id: String { storeName }

    static func read(
        legacyContainer: ModelContainer?,
        userStateContainer: ModelContainer?,
        cacheContainer: ModelContainer?
    ) -> [StoreSplitDevelopmentDatabaseCounts] {
        [
            legacyCounts(from: legacyContainer),
            userStateCounts(from: userStateContainer),
            cacheCounts(from: cacheContainer)
        ]
    }

    private static func legacyCounts(
        from container: ModelContainer?
    ) -> StoreSplitDevelopmentDatabaseCounts {
        guard let container else {
            return unavailable("SharedDatabase.sqlite")
        }

        let context = ModelContext(container)
        return available(
            "SharedDatabase.sqlite",
            objects: [
                count("Podcasts", Podcast.self, in: context),
                count("Subscribed podcasts", legacySubscribedPodcastCount(in: context)),
                count("Episodes", Episode.self, in: context),
                count("Playlists", Playlist.self, in: context),
                count("Playlist entries", legacyPlaylistEntryCount(in: context)),
                count("Queue entries", legacyQueueEntryCount(in: context)),
                count("Bookmarks", legacyBookmarkCount(in: context)),
                count("Playback state", legacyPlaybackStateCount(in: context)),
                count("Listening statistics", PlaySessionSummary.self, in: context),
                count("Listening history", legacyListeningHistoryCount(in: context)),
                count("Transcript records", TranscriptionRecord.self, in: context),
                count("Transcript lines", TranscriptLineAndTime.self, in: context),
                count("AI transcripts", legacyAITranscriptCount(in: context)),
                count("AI transcript chunks", nil),
                count("AI chapters", legacyAIChapterSetCount(in: context))
            ]
        )
    }

    private static func userStateCounts(
        from container: ModelContainer?
    ) -> StoreSplitDevelopmentDatabaseCounts {
        guard let container else {
            return unavailable("UserState.sqlite")
        }

        let context = ModelContext(container)
        return available(
            "UserState.sqlite",
            objects: [
                count("Podcasts", nil),
                count(
                    "Subscribed podcasts",
                    uniqueCount(
                        SubscriptionSync.self,
                        in: context,
                        include: { $0.isSubscribed && $0.unsubscribedAt == nil },
                        key: {
                            URL(string: $0.feedURL)
                                .map(PodcastFeedIdentity.normalizedFeedURLString)
                                ?? $0.feedURL
                        }
                    )
                ),
                count("Episodes", nil),
                count(
                    "Playlists",
                    uniqueCount(
                        PlaylistSync.self,
                        in: context,
                        include: { $0.isDeleted == false && $0.deletedAt == nil },
                        key: \.id
                    )
                ),
                count(
                    "Playlist entries",
                    uniqueCount(
                        PlaylistEntrySync.self,
                        in: context,
                        include: { $0.isDeleted == false && $0.deletedAt == nil },
                        key: \.id
                    )
                ),
                count(
                    "Queue entries",
                    uniqueCount(
                        QueueEntrySync.self,
                        in: context,
                        include: { $0.isDeleted == false && $0.deletedAt == nil },
                        key: \.id
                    )
                ),
                count(
                    "Bookmarks",
                    uniqueCount(
                        BookmarkSync.self,
                        in: context,
                        include: { $0.isDeleted == false && $0.deletedAt == nil },
                        key: \.id
                    )
                ),
                uniqueCount("Playback state", EpisodeStateSync.self, in: context, key: \.id),
                uniqueCount("Listening statistics", ListeningBaselineSync.self, in: context, key: \.id),
                uniqueCount("Listening history", ListeningHistorySync.self, in: context, key: \.id),
                count("Transcript records", nil),
                count("Transcript lines", nil),
                count("AI transcripts", nil),
                count("AI transcript chunks", nil),
                count("AI chapters", nil)
            ]
        )
    }

    private static func cacheCounts(
        from container: ModelContainer?
    ) -> StoreSplitDevelopmentDatabaseCounts {
        guard let container else {
            return unavailable("PodcastCache.sqlite")
        }

        let context = ModelContext(container)
        return available(
            "PodcastCache.sqlite",
            objects: [
                count("Podcasts", CachedPodcast.self, in: context),
                count("Subscribed podcasts", nil),
                count("Episodes", CachedEpisode.self, in: context),
                count("Playlists", nil),
                count("Playlist entries", nil),
                count("Queue entries", nil),
                count("Bookmarks", nil),
                count("Playback state", nil),
                count("Listening statistics", nil),
                count("Listening history", CachedPlaySession.self, in: context),
                count("Transcript records", CachedTranscriptionRecord.self, in: context),
                count("Transcript lines", CachedTranscriptLine.self, in: context),
                uniqueCount("AI transcripts", AITranscriptSync.self, in: context, key: \.id),
                uniqueCount("AI transcript chunks", AITranscriptChunkSync.self, in: context, key: \.id),
                uniqueCount("AI chapters", AIChapterSetSync.self, in: context, key: \.id)
            ]
        )
    }

    private static func available(
        _ storeName: String,
        objects: [StoreSplitDevelopmentObjectCount]
    ) -> StoreSplitDevelopmentDatabaseCounts {
        let objectsByName = Dictionary(
            uniqueKeysWithValues: objects.map { ($0.name, $0) }
        )
        return StoreSplitDevelopmentDatabaseCounts(
            storeName: storeName,
            objects: metricNames.map {
                objectsByName[$0]
                    ?? StoreSplitDevelopmentObjectCount(name: $0, count: nil)
            },
            isAvailable: true
        )
    }

    private static func unavailable(
        _ storeName: String
    ) -> StoreSplitDevelopmentDatabaseCounts {
        StoreSplitDevelopmentDatabaseCounts(
            storeName: storeName,
            objects: metricNames.map { StoreSplitDevelopmentObjectCount(name: $0, count: nil) },
            isAvailable: false
        )
    }

    private static let metricNames = [
        "Podcasts",
        "Subscribed podcasts",
        "Episodes",
        "Playlists",
        "Playlist entries",
        "Queue entries",
        "Bookmarks",
        "Playback state",
        "Listening statistics",
        "Listening history",
        "Transcript records",
        "Transcript lines",
        "AI transcripts",
        "AI transcript chunks",
        "AI chapters"
    ]

    private static func count<Model: PersistentModel>(
        _ name: String,
        _ type: Model.Type,
        in context: ModelContext
    ) -> StoreSplitDevelopmentObjectCount {
        StoreSplitDevelopmentObjectCount(
            name: name,
            count: (try? context.fetchCount(FetchDescriptor<Model>())) ?? 0
        )
    }

    private static func count<Model: PersistentModel>(
        _ name: String,
        descriptor: FetchDescriptor<Model>,
        in context: ModelContext
    ) -> StoreSplitDevelopmentObjectCount {
        StoreSplitDevelopmentObjectCount(
            name: name,
            count: (try? context.fetchCount(descriptor)) ?? 0
        )
    }

    private static func uniqueCount<Model: PersistentModel, Key: Hashable>(
        _ name: String,
        _ type: Model.Type,
        in context: ModelContext,
        include: (Model) -> Bool = { _ in true },
        key: (Model) -> Key
    ) -> StoreSplitDevelopmentObjectCount {
        let records = (try? context.fetch(FetchDescriptor<Model>())) ?? []
        return StoreSplitDevelopmentObjectCount(
            name: name,
            count: Set(records.filter(include).map(key)).count
        )
    }

    private static func uniqueCount<Model: PersistentModel, Key: Hashable>(
        _ type: Model.Type,
        in context: ModelContext,
        include: @escaping (Model) -> Bool = { _ in true },
        key: @escaping (Model) -> Key
    ) -> Int {
        let records = (try? context.fetch(FetchDescriptor<Model>())) ?? []
        return Set(records.filter(include).map(key)).count
    }

    private static func count(
        _ name: String,
        _ count: Int?
    ) -> StoreSplitDevelopmentObjectCount {
        StoreSplitDevelopmentObjectCount(name: name, count: count)
    }

    private static func legacyQueueEntryCount(in context: ModelContext) -> Int {
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        return playlists
            .first(where: { $0.title == Playlist.defaultQueueTitle })?
            .ordered.compactMap { entry -> String? in
                guard let episode = entry.episode,
                      episode.podcast?.feed != nil else { return nil }
                return episode.stableEpisodeIdentity.key
            }
            .reduce(into: Set<String>()) { $0.insert($1) }
            .count ?? 0
    }

    private static func legacyPlaylistEntryCount(in context: ModelContext) -> Int {
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        var IDs = Set<String>()
        for playlist in playlists {
            for entry in playlist.ordered {
                guard let episode = entry.episode,
                      episode.podcast?.feed != nil else { continue }
                let identity = episode.stableEpisodeIdentity
                IDs.insert(
                    StableIdentityKey.make(
                        playlist.storeSplitSyncID,
                        identity.feedURL,
                        identity.episodeID
                    )
                )
            }
        }
        return IDs.count
    }

    private static func legacySubscribedPodcastCount(in context: ModelContext) -> Int {
        let podcasts = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []
        let feedKeys: [String] = podcasts.compactMap { podcast in
            guard podcast.metaData?.isSubscribed != false,
                  let feed = podcast.feed else { return nil }
            return PodcastFeedIdentity.normalizedFeedURLString(feed)
        }
        return Set(feedKeys).count
    }

    private static func legacyBookmarkCount(in context: ModelContext) -> Int {
        let bookmarks = (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        var IDs = Set<String>()
        for bookmark in bookmarks {
            guard let episode = bookmark.bookmarkEpisode,
                  episode.podcast?.feed != nil else { continue }
            let identity = episode.stableEpisodeIdentity
            let createdAt = bookmark.creationtime ?? .distantPast
            IDs.insert(
                bookmark.uuid?.uuidString ?? StableIdentityKey.make(
                    "legacy-bookmark",
                    identity.key,
                    String(bookmark.start ?? 0),
                    bookmark.title,
                    String(createdAt.timeIntervalSince1970)
                )
            )
        }
        return IDs.count
    }

    private static func legacyPlaybackStateCount(in context: ModelContext) -> Int {
        let episodes = (try? context.fetch(FetchDescriptor<Episode>())) ?? []
        return Set(episodes.compactMap { episode -> String? in
            guard episode.podcast?.feed != nil else { return nil }
            guard let metadata = episode.metaData else { return nil }
            let meaningful = (metadata.playPosition ?? 0) > 0
                || (metadata.maxPlayposition ?? 0) > 0
                || metadata.isHistory == true
                || metadata.isArchived == true
                || metadata.status == .history
                || metadata.status == .archived
                || metadata.wasSkipped
                || metadata.firstListenDate != nil
                || metadata.lastPlayed != nil
            return meaningful ? episode.stableEpisodeIdentity.key : nil
        }).count
    }

    private static func legacyListeningHistoryCount(in context: ModelContext) -> Int {
        let sessions = (try? context.fetch(FetchDescriptor<PlaySession>())) ?? []
        return sessions.filter { session in
            guard let episode = session.episode,
                  episode.podcast?.feed != nil,
                  let startedAt = session.startTime,
                  let endedAt = session.endTime else {
                return false
            }
            return endedAt > startedAt
                && session.appVersion
                    != ListeningDeviceIdentity.splitStoreProjectionAppVersion
        }.count
    }

    private static func legacyAITranscriptCount(in context: ModelContext) -> Int {
        let records = (try? context.fetch(FetchDescriptor<TranscriptionRecord>())) ?? []
        let latest = records.reduce(into: Set<URL>()) { result, record in
            guard let episodeURL = record.episodeURL else { return }
            result.insert(episodeURL)
        }
        return latest.filter { episodeURL in
            let descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { $0.url == episodeURL }
            )
            guard let episode = (try? context.fetch(descriptor))?.first else {
                return false
            }
            return episode.transcriptLines?.isEmpty == false
        }.count
    }

    private static func legacyAIChapterSetCount(in context: ModelContext) -> Int {
        let episodes = (try? context.fetch(FetchDescriptor<Episode>())) ?? []
        return episodes.filter { episode in
            episode.chapters?.contains { $0.type == .ai } == true
        }.count
    }
}

struct StoreSplitCacheDevelopmentStatus: Sendable {
    let readinessStatus: StoreSplitFeedCacheReadiness.Status
    let readinessFailureStage: String?
    let sourceFeedCount: Int
    let cachedFeedCount: Int
    let pendingFeedCount: Int
    let cachedEpisodeCount: Int
    let cachedTranscriptCount: Int
    let cachedTranscriptLineCount: Int
    let cachedChapterCount: Int
    let failedOrRetryableFeedCount: Int
    let rssRecoverablePendingFeedCount: Int
    let unverifiedRecoverabilityFeedCount: Int
    let cacheSchemaVersion: Int
    let lastSuccessfulProgressAt: Date?
    let lastRefreshProjectionAt: Date?
    let lastRefreshProjectionStatus: String?
    let lastRefreshProjectionEpisodes: Int?

    var isComplete: Bool {
        readinessStatus == .ready
            && pendingFeedCount == 0
            && failedOrRetryableFeedCount == 0
            && unverifiedRecoverabilityFeedCount == 0
    }

    var readinessStatusDescription: String {
        switch readinessStatus {
        case .ready: return isComplete ? "Ready" : "Filling"
        case .incomplete: return "Incomplete"
        case .unavailable: return "Unavailable"
        }
    }

    static func read(
        legacyContainer: ModelContainer,
        cacheContainer: ModelContainer
    ) -> Self {
        let legacy = ModelContext(legacyContainer)
        let cache = ModelContext(cacheContainer)
        let defaults = UserDefaults(suiteName: ModelContainerManager.appGroupID)
            ?? .standard
        let readiness = StoreSplitFeedCacheReadiness.read(
            legacyContext: legacy,
            cacheContext: cache
        )
        return Self(
            readinessStatus: readiness.status,
            readinessFailureStage: readiness.failureStage,
            sourceFeedCount: readiness.subscribedFeedCount,
            cachedFeedCount: readiness.readyFeedCount,
            pendingFeedCount: readiness.pendingFeedCount,
            cachedEpisodeCount: readiness.cachedEpisodeCount,
            cachedTranscriptCount: uniqueCount(CachedTranscriptionRecord.self, in: cache, key: \.id),
            cachedTranscriptLineCount: uniqueCount(CachedTranscriptLine.self, in: cache, key: \.id),
            cachedChapterCount: uniqueCount(CachedChapter.self, in: cache, key: \.id),
            failedOrRetryableFeedCount: readiness.failedOrRetryableFeedCount,
            rssRecoverablePendingFeedCount: readiness.rssRecoverablePendingFeedCount,
            unverifiedRecoverabilityFeedCount: readiness.unverifiedRecoverabilityFeedCount,
            cacheSchemaVersion: readiness.cacheSchemaVersion,
            lastSuccessfulProgressAt: readiness.lastSuccessfulProgressAt,
            lastRefreshProjectionAt: defaults.object(forKey: "storeSplit.cacheRefreshLastAttemptAt") as? Date,
            lastRefreshProjectionStatus: defaults.string(forKey: "storeSplit.cacheRefreshLastStatus"),
            lastRefreshProjectionEpisodes: defaults.object(forKey: "storeSplit.cacheRefreshLastEpisodeCount") as? Int
        )
    }

    private static func uniqueCount<Model: PersistentModel, Key: Hashable>(
        _ type: Model.Type,
        in context: ModelContext,
        key: (Model) -> Key
    ) -> Int {
        Set(((try? context.fetch(FetchDescriptor<Model>())) ?? []).map(key)).count
    }
}
#endif
