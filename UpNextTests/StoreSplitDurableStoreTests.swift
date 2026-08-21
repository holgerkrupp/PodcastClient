import SwiftData
import XCTest
@testable import UpNext

/// Covers the invariant that makes the store split invisible to existing users:
/// the app's library graph stays on disk, and only user-owned state travels
/// through `UserState.sqlite`.
final class StoreSplitDurableStoreTests: XCTestCase {
    func testOnlyTheExperimentalModeRebuildsTheLibraryInMemory() {
        XCTAssertFalse(DevelopmentStoreMode.legacyOnly.usesInMemoryLibraryProjection)
        XCTAssertFalse(DevelopmentStoreMode.splitStores.usesInMemoryLibraryProjection)
        XCTAssertFalse(DevelopmentStoreMode.splitStoreReads.usesInMemoryLibraryProjection)
        XCTAssertTrue(DevelopmentStoreMode.newStoresOnly.usesInMemoryLibraryProjection)
    }

    /// UserState always syncs in the shipping modes. Whether the *library* store
    /// also syncs is the release phase's decision: it does during the backfill
    /// ship, and dropping it in the authority ship is the payload win.
    func testShippingModesAlwaysSyncUserState() {
        for mode in [DevelopmentStoreMode.splitStores, .splitStoreReads] {
            let configuration = StoreDevelopmentConfiguration(
                mode: mode,
                legacyCloudSyncEnabled: StoreDevelopmentConfiguration
                    .releaseLegacyCloudSyncEnabled,
                userStateCloudSyncEnabled: true,
                splitStoreWorkEnabled: true
            )
            XCTAssertTrue(configuration.effectiveUserStateCloudSyncEnabled)
            XCTAssertEqual(
                configuration.effectiveLegacyCloudSyncEnabled,
                StoreSplitReleasePhase.current == .dualSyncBackfill,
                "\(mode) library sync must follow the release phase"
            )
        }
    }

    // MARK: - Additive recovery from a cache-only phase

    @MainActor
    func testCacheRecoveryAddsMissingFeedsWithoutTouchingDurableRows() throws {
        let runtime = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let cacheSource = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let cache = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)

        // Feed A exists on disk with a user-edited title; feed B was only ever
        // written to the cache while the runtime graph lived in memory.
        let keptFeed = URL(string: "https://example.com/kept.xml")!
        let cacheOnlyFeed = URL(string: "https://example.com/cache-only.xml")!

        let durablePodcast = Podcast(feed: keptFeed)
        durablePodcast.title = "Durable title"
        let durableEpisode = Episode(
            guid: "kept-1",
            title: "Kept episode",
            url: URL(string: "https://example.com/kept-1.mp3")!,
            podcast: durablePodcast
        )
        durablePodcast.episodes = [durableEpisode]
        runtime.mainContext.insert(durablePodcast)
        runtime.mainContext.insert(durableEpisode)
        try runtime.mainContext.save()

        try seedCache(
            cache,
            from: cacheSource,
            feeds: [
                (keptFeed, "Stale cached title", ["kept-1", "kept-2"]),
                (cacheOnlyFeed, "Cache only", ["cache-1"])
            ]
        )

        let result = StoreSplitCompatibilityProjectionService.recoverMissingLibraryData(
            cacheContainer: cache,
            runtimeContainer: runtime,
            recoverableFeedKeys: [
                PodcastFeedIdentity.normalizedFeedURLString(keptFeed),
                PodcastFeedIdentity.normalizedFeedURLString(cacheOnlyFeed)
            ]
        )
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.podcasts, 1, "only the cache-only feed is new")
        XCTAssertEqual(result.episodes, 2, "kept-2 plus the cache-only episode")

        let context = ModelContext(runtime)
        let podcasts = try context.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(podcasts.count, 2)
        let kept = try XCTUnwrap(podcasts.first { $0.feed == keptFeed })
        XCTAssertEqual(
            kept.title,
            "Durable title",
            "recovery must never overwrite a durable row"
        )
        XCTAssertEqual(kept.episodes?.count, 2)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<Episode>()),
            3
        )
    }

    @MainActor
    func testCacheRecoveryIsIdempotent() throws {
        let runtime = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let cacheSource = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let cache = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        let feed = URL(string: "https://example.com/repeat.xml")!

        try seedCache(
            cache,
            from: cacheSource,
            feeds: [(feed, "Repeatable", ["a", "b", "c"])]
        )

        let feedKeys: Set<String> = [
            PodcastFeedIdentity.normalizedFeedURLString(feed)
        ]
        let first = StoreSplitCompatibilityProjectionService.recoverMissingLibraryData(
            cacheContainer: cache,
            runtimeContainer: runtime,
            recoverableFeedKeys: feedKeys
        )
        XCTAssertEqual(first.podcasts, 1)
        XCTAssertEqual(first.episodes, 3)

        let second = StoreSplitCompatibilityProjectionService.recoverMissingLibraryData(
            cacheContainer: cache,
            runtimeContainer: runtime,
            recoverableFeedKeys: feedKeys
        )
        XCTAssertEqual(second.podcasts, 0)
        XCTAssertEqual(second.episodes, 0)

        let context = ModelContext(runtime)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 3)
    }

    /// Deleting a podcast removes it from the durable store but leaves its cache
    /// rows behind. Recovery must not bring it back.
    @MainActor
    func testCacheRecoverySkipsFeedsThatAreNoLongerSubscribed() throws {
        let runtime = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let cacheSource = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let cache = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        let deletedFeed = URL(string: "https://example.com/deleted.xml")!
        let keptFeed = URL(string: "https://example.com/still-subscribed.xml")!

        try seedCache(
            cache,
            from: cacheSource,
            feeds: [
                (deletedFeed, "Deleted", ["gone-1", "gone-2"]),
                (keptFeed, "Kept", ["kept-1"])
            ]
        )

        let result = StoreSplitCompatibilityProjectionService.recoverMissingLibraryData(
            cacheContainer: cache,
            runtimeContainer: runtime,
            recoverableFeedKeys: [
                PodcastFeedIdentity.normalizedFeedURLString(keptFeed)
            ]
        )
        XCTAssertEqual(result.podcasts, 1)
        XCTAssertEqual(result.episodes, 1)

        let context = ModelContext(runtime)
        let podcasts = try context.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(podcasts.count, 1)
        XCTAssertEqual(podcasts.first?.feed, keptFeed)
    }

    // MARK: - Stale synchronized state must not roll back durable state

    @MainActor
    func testOlderSyncedStateDoesNotRollBackDurablePlaybackState() async throws {
        let runtime = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let feed = URL(string: "https://example.com/merge.xml")!
        let podcast = Podcast(feed: feed)
        let episode = Episode(
            guid: "merge-1",
            title: "Merge",
            url: URL(string: "https://example.com/merge-1.mp3")!,
            podcast: podcast
        )
        podcast.episodes = [episode]
        let now = Date()
        episode.metaData?.playPosition = 900
        episode.metaData?.maxPlayposition = 900
        episode.metaData?.lastPlayed = now
        episode.metaData?.stateUpdatedAt = now
        runtime.mainContext.insert(podcast)
        runtime.mainContext.insert(episode)
        try runtime.mainContext.save()

        let identity = episode.stableEpisodeIdentity
        userState.mainContext.insert(EpisodeStateSync(
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            playPosition: 10,
            maxPlayPosition: 1200,
            isPlayed: false,
            isArchived: false,
            lastPlayedAt: now.addingTimeInterval(-3600),
            updatedAt: now.addingTimeInterval(-3600)
        ))
        try userState.mainContext.save()

        _ = await StoreSplitUserStateImporter.apply(
            legacyContainer: runtime,
            userStateContainer: userState,
            projectListeningHistoryToLegacy: false
        )

        let context = ModelContext(runtime)
        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<Episode>()).first)
        XCTAssertEqual(stored.metaData?.playPosition, 900, "stale record must not rewind playback")
        XCTAssertEqual(
            stored.metaData?.maxPlayposition,
            1200,
            "the furthest point reached on any device still merges upwards"
        )
    }

    @MainActor
    func testNewerSyncedStateIsApplied() async throws {
        let runtime = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let feed = URL(string: "https://example.com/newer.xml")!
        let podcast = Podcast(feed: feed)
        let episode = Episode(
            guid: "newer-1",
            title: "Newer",
            url: URL(string: "https://example.com/newer-1.mp3")!,
            podcast: podcast
        )
        podcast.episodes = [episode]
        let past = Date().addingTimeInterval(-7200)
        episode.metaData?.playPosition = 30
        episode.metaData?.maxPlayposition = 30
        episode.metaData?.lastPlayed = past
        episode.metaData?.stateUpdatedAt = past
        runtime.mainContext.insert(podcast)
        runtime.mainContext.insert(episode)
        try runtime.mainContext.save()

        let identity = episode.stableEpisodeIdentity
        let recent = Date()
        userState.mainContext.insert(EpisodeStateSync(
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            playPosition: 640,
            maxPlayPosition: 640,
            isPlayed: true,
            isArchived: false,
            completedAt: recent,
            lastPlayedAt: recent,
            updatedAt: recent
        ))
        try userState.mainContext.save()

        _ = await StoreSplitUserStateImporter.apply(
            legacyContainer: runtime,
            userStateContainer: userState,
            projectListeningHistoryToLegacy: false
        )

        let context = ModelContext(runtime)
        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<Episode>()).first)
        XCTAssertEqual(stored.metaData?.playPosition, 640)
        XCTAssertEqual(stored.metaData?.isHistory, true)
    }

    // MARK: - Helpers

    /// Populates a cache container by projecting a throwaway model graph through
    /// the production feed-cache writer, so the rows under test are shaped
    /// exactly like the ones a real cache-only phase would have written.
    @MainActor
    private func seedCache(
        _ cache: ModelContainer,
        from source: ModelContainer,
        feeds: [(URL, String, [String])]
    ) throws {
        for (feed, title, guids) in feeds {
            let podcast = Podcast(feed: feed)
            podcast.title = title
            podcast.episodes = guids.map { guid in
                let episode = Episode(
                    guid: guid,
                    title: guid,
                    url: URL(string: "https://example.com/\(guid).mp3")!,
                    podcast: podcast
                )
                source.mainContext.insert(episode)
                return episode
            }
            source.mainContext.insert(podcast)
        }
        try source.mainContext.save()

        for (feed, _, _) in feeds {
            XCTAssertTrue(StoreSplitFeedCacheWriter.upsertFeed(
                feedURL: feed,
                legacyContainer: source,
                cacheContainer: cache
            ))
        }
    }
}

/// Playback republishes episode state every ten seconds. Each republish that
/// reaches SwiftData is a write to the synced store and a CloudKit export, so a
/// no-op republish has to be recognised as one.
final class StoreSplitEpisodeStateWriteVolumeTests: XCTestCase {
    @MainActor
    func testRepublishingUnchangedStateDoesNotRewriteTheRecord() async throws {
        let userState = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let writer = StoreSplitEpisodeStateSyncWriter(modelContainer: userState)
        let identity = EpisodeStableIdentity(
            feedURL: "https://example.com/feed.xml",
            episodeID: "guid:episode"
        )
        func snapshot(playPosition: Double) -> StoreSplitEpisodeStateSnapshot {
            StoreSplitEpisodeStateSnapshot(
                identity: identity,
                playPosition: playPosition,
                maxPlayPosition: playPosition,
                duration: 3_600,
                isPlayed: false,
                isArchived: false,
                wasSkipped: false,
                completedAt: nil,
                archivedAt: nil,
                firstPlayedAt: nil,
                lastPlayedAt: nil
            )
        }

        let first = Date()
        let firstWrite = await writer.upsert(snapshot(playPosition: 100), at: first)
        XCTAssertTrue(firstWrite)

        let context = ModelContext(userState)
        let stored = try XCTUnwrap(
            context.fetch(FetchDescriptor<EpisodeStateSync>()).first
        )
        XCTAssertEqual(stored.updatedAt, first)

        // Identical state, and a sub-threshold nudge: neither is worth a write.
        let identicalWrite = await writer.upsert(
            snapshot(playPosition: 100),
            at: first.addingTimeInterval(10)
        )
        XCTAssertFalse(identicalWrite)
        let nudgeWrite = await writer.upsert(
            snapshot(playPosition: 101),
            at: first.addingTimeInterval(20)
        )
        XCTAssertFalse(nudgeWrite)

        let unchangedContext = ModelContext(userState)
        let unchanged = try XCTUnwrap(
            unchangedContext.fetch(FetchDescriptor<EpisodeStateSync>()).first
        )
        XCTAssertEqual(unchanged.updatedAt, first, "no-op republish must not touch updatedAt")
        XCTAssertEqual(unchanged.playPosition, 100)

        // Real progress still gets through.
        let later = first.addingTimeInterval(30)
        let progressWrite = await writer.upsert(snapshot(playPosition: 160), at: later)
        XCTAssertTrue(progressWrite)
        let movedContext = ModelContext(userState)
        let moved = try XCTUnwrap(
            movedContext.fetch(FetchDescriptor<EpisodeStateSync>()).first
        )
        XCTAssertEqual(moved.playPosition, 160)
        XCTAssertEqual(moved.updatedAt, later)
    }
}

/// The backfill has to finish without anyone tapping anything, so the conditions
/// that decide whether it is scheduled are covered on their own.
final class StoreSplitAutomaticMigrationTests: XCTestCase {
    private let completedVersionKey = "storeSplit.completedMigrationVersion"

    private var defaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    }

    override func tearDown() {
        defaults.removeObject(forKey: completedVersionKey)
        super.tearDown()
    }

    func testPendingWorkIsTrueUntilTheCurrentVersionCompletes() {
        defaults.removeObject(forKey: completedVersionKey)
        XCTAssertTrue(
            ModelContainerManager.hasPendingMigrationWork,
            "a device that has never completed a migration owes work"
        )

        defaults.set(
            StoreSplitMigrationService.migrationVersion - 1,
            forKey: completedVersionKey
        )
        XCTAssertTrue(
            ModelContainerManager.hasPendingMigrationWork,
            "an older completed version must not suppress the current one"
        )

        defaults.set(
            StoreSplitMigrationService.migrationVersion,
            forKey: completedVersionKey
        )
        XCTAssertFalse(ModelContainerManager.hasPendingMigrationWork)
    }

    /// The rollout marker used to gate the overnight task, which meant a device
    /// sitting at `newStoreReads` from an older version never scheduled it.
    func testPendingWorkIsIndependentOfTheRolloutMarker() {
        defaults.set(
            StoreSplitMigrationService.migrationVersion - 1,
            forKey: completedVersionKey
        )
        let rolloutDefaults = UserDefaults(suiteName: ModelContainerManager.appGroupID)
            ?? .standard
        let previousState = rolloutDefaults.string(forKey: StoreSplitRollout.stateKey)
        defer {
            if let previousState {
                rolloutDefaults.set(previousState, forKey: StoreSplitRollout.stateKey)
            } else {
                rolloutDefaults.removeObject(forKey: StoreSplitRollout.stateKey)
            }
        }

        rolloutDefaults.set(
            StoreSplitRolloutState.newStoreReads.rawValue,
            forKey: StoreSplitRollout.stateKey
        )
        XCTAssertEqual(StoreSplitRollout.state, .newStoreReads)
        XCTAssertTrue(ModelContainerManager.hasPendingMigrationWork)
    }
}
