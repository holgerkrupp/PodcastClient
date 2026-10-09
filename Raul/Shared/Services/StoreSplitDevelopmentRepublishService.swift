#if DEBUG
import Foundation
import SwiftData

struct StoreSplitDevelopmentRepublishResult: Sendable {
    var subscriptions = 0
    var episodeStates = 0
    var playlists = 0
    var bookmarks = 0
    var listeningSessions = 0
    var storedCounts = StoreSplitDevelopmentStoreCounts()
}

enum StoreSplitDevelopmentRepublishScope: Sendable {
    case subscriptions
    case episodeStates
    case playlists
    case bookmarks
    case listeningHistory
}

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
    let sourceFeedCount: Int
    let cachedFeedCount: Int
    let pendingFeedCount: Int
    let cachedEpisodeCount: Int
    let cachedTranscriptCount: Int
    let cachedTranscriptLineCount: Int
    let cachedChapterCount: Int
    let automaticFillingEnabled: Bool
    let failedOrRetryableFeedCount: Int
    let rssRecoverablePendingFeedCount: Int
    let cacheSchemaVersion: Int
    let lastSuccessfulProgressAt: Date?
    let lastBootstrapAt: Date?
    let lastBootstrapCopied: Int?

    var isComplete: Bool {
        pendingFeedCount == 0
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
            sourceFeedCount: readiness.subscribedFeedCount,
            cachedFeedCount: readiness.readyFeedCount,
            pendingFeedCount: readiness.pendingFeedCount,
            cachedEpisodeCount: uniqueCount(CachedEpisode.self, in: cache, key: \.id),
            cachedTranscriptCount: uniqueCount(CachedTranscriptionRecord.self, in: cache, key: \.id),
            cachedTranscriptLineCount: uniqueCount(CachedTranscriptLine.self, in: cache, key: \.id),
            cachedChapterCount: uniqueCount(CachedChapter.self, in: cache, key: \.id),
            automaticFillingEnabled: StoreDevelopmentConfiguration.feedCachePrewarmingEnabled,
            failedOrRetryableFeedCount: readiness.failedOrRetryableFeedCount,
            rssRecoverablePendingFeedCount: readiness.rssRecoverablePendingFeedCount,
            cacheSchemaVersion: readiness.cacheSchemaVersion,
            lastSuccessfulProgressAt: readiness.lastSuccessfulProgressAt,
            lastBootstrapAt: defaults.object(forKey: "storeSplit.cacheBootstrapLastAt") as? Date,
            lastBootstrapCopied: defaults.object(forKey: "storeSplit.cacheBootstrapLastCopied") as? Int
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

actor StoreSplitDevelopmentRepublishService {
    private let legacyContainer: ModelContainer
    private let userStateContainer: ModelContainer
    private let episodePageSize = 100
    private let historyPageSize = 25

    private init(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer
    ) {
        self.legacyContainer = legacyContainer
        self.userStateContainer = userStateContainer
    }

    nonisolated static func republish(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer,
        scope: StoreSplitDevelopmentRepublishScope
    ) async -> StoreSplitDevelopmentRepublishResult {
        let service = StoreSplitDevelopmentRepublishService(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer
        )
        return await service.run(scope: scope)
    }

    private func run(
        scope: StoreSplitDevelopmentRepublishScope
    ) async -> StoreSplitDevelopmentRepublishResult {
        var result = StoreSplitDevelopmentRepublishResult()
        let now = Date()
        switch scope {
        case .subscriptions:
            await republishSubscriptions(now: now, result: &result)
        case .episodeStates:
            await republishEpisodeStates(now: now, result: &result)
        case .playlists:
            await republishPlaylists(now: now, result: &result)
        case .bookmarks:
            await republishBookmarks(now: now, result: &result)
        case .listeningHistory:
            await republishListeningHistory(result: &result)
        }
        result.storedCounts = StoreSplitDevelopmentStoreCounts.read(
            from: userStateContainer
        )
        return result
    }

    private func republishSubscriptions(
        now: Date,
        result: inout StoreSplitDevelopmentRepublishResult
    ) async {
        let subscriptionWriter = StoreSplitSubscriptionSyncWriter(
            modelContainer: userStateContainer
        )
        let context = ModelContext(legacyContainer)
        for podcast in (try? context.fetch(FetchDescriptor<Podcast>())) ?? [] {
            guard let feed = podcast.feed else { continue }
            _ = try? await subscriptionWriter.setSubscribed(
                feedURL: feed,
                isSubscribed: podcast.metaData?.isSubscribed != false,
                accessProfile: storedPodcastAccessProfile(for: podcast),
                at: now
            )
            result.subscriptions += 1
        }
    }

    private func republishEpisodeStates(
        now: Date,
        result: inout StoreSplitDevelopmentRepublishResult
    ) async {
        var episodeOffset = 0
        while true {
            let page = episodeStateSnapshots(
                offset: episodeOffset,
                limit: episodePageSize
            )
            guard page.fetchedCount > 0 else { break }
            if page.snapshots.isEmpty == false {
                await StoreSplitEpisodeStateSyncWriter(
                    modelContainer: userStateContainer
                ).upsert(page.snapshots, at: now)
                result.episodeStates += page.snapshots.count
            }
            episodeOffset += page.fetchedCount
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func republishPlaylists(
        now: Date,
        result: inout StoreSplitDevelopmentRepublishResult
    ) async {
        let context = ModelContext(legacyContainer)
        let playlistWriter = StoreSplitPlaylistSyncWriter(
            modelContainer: userStateContainer
        )
        for playlist in (try? context.fetch(FetchDescriptor<Playlist>())) ?? [] {
            removeDuplicateEntries(from: playlist, in: context)
            await playlistWriter.upsert(
                playlist.storeSplitSnapshot,
                at: now,
                authoritative: true
            )
            result.playlists += 1
        }
        context.saveIfNeeded()
    }

    private func republishBookmarks(
        now: Date,
        result: inout StoreSplitDevelopmentRepublishResult
    ) async {
        let context = ModelContext(legacyContainer)
        let bookmarkWriter = StoreSplitBookmarkSyncWriter(
            modelContainer: userStateContainer
        )
        for bookmark in (try? context.fetch(FetchDescriptor<Bookmark>())) ?? [] {
            guard let episode = bookmark.bookmarkEpisode,
                  let bookmarkID = bookmark.uuid?.uuidString else { continue }
            await bookmarkWriter.upsert(
                StoreSplitBookmarkSnapshot(
                    id: bookmarkID,
                    identity: episode.stableEpisodeIdentity,
                    time: bookmark.start ?? 0,
                    title: bookmark.title,
                    createdAt: bookmark.creationtime ?? now
                ),
                at: now
            )
            result.bookmarks += 1
        }
    }

    private func republishListeningHistory(
        result: inout StoreSplitDevelopmentRepublishResult
    ) async {
        var historyOffset = 0
        while true {
            let page = listeningHistorySnapshots(
                offset: historyOffset,
                limit: historyPageSize
            )
            guard page.fetchedCount > 0 else { break }
            if page.snapshots.isEmpty == false {
                await StoreSplitListeningHistorySyncWriter(
                    modelContainer: userStateContainer
                ).upsert(page.snapshots)
                result.listeningSessions += page.snapshots.count
            }
            historyOffset += page.fetchedCount
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func episodeStateSnapshots(
        offset: Int,
        limit: Int
    ) -> (fetchedCount: Int, snapshots: [StoreSplitEpisodeStateSnapshot]) {
        autoreleasepool {
            let context = ModelContext(legacyContainer)
            var descriptor = FetchDescriptor<Episode>()
            descriptor.fetchLimit = limit
            descriptor.fetchOffset = offset
            let episodes = (try? context.fetch(descriptor)) ?? []
            let snapshots: [StoreSplitEpisodeStateSnapshot] =
                episodes.compactMap { episode in
                guard let metadata = episode.metaData,
                      episode.podcast?.feed != nil else {
                    return nil
                }
                let snapshot = StoreSplitEpisodeStateSnapshot(
                    identity: episode.stableEpisodeIdentity,
                    playPosition: max(0, metadata.playPosition ?? 0),
                    maxPlayPosition: max(
                        0,
                        metadata.maxPlayposition ?? 0,
                        metadata.playPosition ?? 0
                    ),
                    duration: episode.duration,
                    isPlayed: metadata.completionDate != nil
                        || metadata.isHistory == true,
                    isArchived: metadata.isArchived == true
                        || metadata.status == .archived,
                    wasSkipped: metadata.wasSkipped,
                    completedAt: metadata.completionDate,
                    archivedAt: metadata.archivedAt,
                    firstPlayedAt: metadata.firstListenDate,
                    lastPlayedAt: metadata.lastPlayed
                )
                guard snapshot.hasUserOwnedState else { return nil }
                return snapshot
            }
            return (episodes.count, snapshots)
        }
    }

    private func listeningHistorySnapshots(
        offset: Int,
        limit: Int
    ) -> (fetchedCount: Int, snapshots: [StoreSplitListeningHistorySnapshot]) {
        autoreleasepool {
            let context = ModelContext(legacyContainer)
            var descriptor = FetchDescriptor<PlaySession>()
            descriptor.fetchLimit = limit
            descriptor.fetchOffset = offset
            let sessions = (try? context.fetch(descriptor)) ?? []
            let snapshots: [StoreSplitListeningHistorySnapshot] =
                sessions.compactMap { session in
                guard let episode = session.episode,
                      let startedAt = session.startTime,
                      let endedAt = session.endTime,
                      endedAt > startedAt else {
                    return nil
                }
                let identity = episode.stableEpisodeIdentity
                return StoreSplitListeningHistorySnapshot(
                    id: ListeningHistoryIdentity.make(
                        feedURL: identity.feedURL,
                        episodeID: identity.episodeID,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        startPosition: session.startPosition ?? 0,
                        endPosition: session.endPosition ?? 0
                    ),
                    identity: identity,
                    podcastName: session.podcastName
                        ?? episode.displayPodcastTitle
                        ?? "Unknown Podcast",
                    episodeTitle: episode.title,
                    sourceDeviceID: session.sourceDeviceID
                        ?? ListeningDeviceIdentity.current().id,
                    sourceDeviceName: session.sourceDeviceName,
                    deviceModel: session.deviceModel,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    startPosition: session.startPosition ?? 0,
                    endPosition: session.endPosition ?? 0,
                    listenedSeconds: endedAt.timeIntervalSince(startedAt),
                    silenceGapTimeSavedSeconds:
                        session.silenceGapTimeSavedSeconds ?? 0,
                    playbackRateTimeSavedSeconds:
                        PlaybackRateSavingsCalculator.secondsSaved(in: session),
                    endedCleanly: session.endedCleanly == true
                )
            }
            return (sessions.count, snapshots)
        }
    }

    private func removeDuplicateEntries(
        from playlist: Playlist,
        in context: ModelContext
    ) {
        var seen = Set<String>()
        var survivors: [PlaylistEntry] = []
        for entry in playlist.ordered {
            guard let episode = entry.episode else {
                context.delete(entry)
                continue
            }
            guard seen.insert(episode.stableEpisodeIdentity.key).inserted else {
                context.delete(entry)
                continue
            }
            entry.order = survivors.count
            survivors.append(entry)
        }
        playlist.items = survivors
    }
}

private extension StoreSplitEpisodeStateSnapshot {
    var hasUserOwnedState: Bool {
        playPosition > 0
            || maxPlayPosition > 0
            || isPlayed
            || isArchived
            || wasSkipped
            || completedAt != nil
            || archivedAt != nil
            || firstPlayedAt != nil
            || lastPlayedAt != nil
    }
}
#endif
