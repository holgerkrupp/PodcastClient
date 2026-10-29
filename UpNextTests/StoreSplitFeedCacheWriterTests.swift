import SwiftData
import XCTest
@testable import UpNext

final class StoreSplitFeedCacheWriterTests: XCTestCase {

    @MainActor
    private func makeContainers() throws -> (legacy: ModelContainer, cache: ModelContainer) {
        (
            legacy: try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true),
            cache: try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        )
    }

    @MainActor
    @discardableResult
    private func makePodcast(
        in container: ModelContainer,
        feed: String,
        episodeGUIDs: [String]
    ) throws -> Podcast {
        let context = container.mainContext
        let podcast = Podcast(feed: URL(string: feed)!)
        podcast.title = "Example"
        context.insert(podcast)
        for guid in episodeGUIDs {
            let episode = Episode(
                guid: guid,
                title: "Title \(guid)",
                publishDate: Date(timeIntervalSince1970: 1_000),
                url: URL(string: "\(feed)/\(guid).mp3")!,
                podcast: podcast,
                duration: 120
            )
            context.insert(episode)
        }
        try context.save()
        return podcast
    }

    private func cacheCounts(
        _ container: ModelContainer
    ) -> (podcasts: Int, episodes: Int) {
        let context = ModelContext(container)
        return (
            (try? context.fetchCount(FetchDescriptor<CachedPodcast>())) ?? -1,
            (try? context.fetchCount(FetchDescriptor<CachedEpisode>())) ?? -1
        )
    }

    @MainActor
    func testBootstrapCopiesFeedAndIsIdempotent() throws {
        let (legacy, cache) = try makeContainers()
        try makePodcast(in: legacy, feed: "https://example.com/a", episodeGUIDs: ["e1", "e2", "e3"])

        let firstPass = StoreSplitFeedCacheWriter.bootstrapMissingFeeds(
            legacyContainer: legacy, cacheContainer: cache, limit: 10
        )
        XCTAssertEqual(firstPass, 1)
        var counts = cacheCounts(cache)
        XCTAssertEqual(counts.podcasts, 1)
        XCTAssertEqual(counts.episodes, 3)

        // The current cache projection version is the checkpoint.
        let secondPass = StoreSplitFeedCacheWriter.bootstrapMissingFeeds(
            legacyContainer: legacy, cacheContainer: cache, limit: 10
        )
        XCTAssertEqual(secondPass, 0)
        counts = cacheCounts(cache)
        XCTAssertEqual(counts.podcasts, 1)
        XCTAssertEqual(counts.episodes, 3)
    }

    @MainActor
    func testAutomaticBootstrapKeepsPendingFlagUntilEntireFeedSourceWasVisited() throws {
        let (legacy, cache) = try makeContainers()
        for index in 0..<3 {
            try makePodcast(
                in: legacy,
                feed: "https://example.com/automatic-cache-\(index)",
                episodeGUIDs: ["episode-\(index)"]
            )
        }

        // The BG executor is allowed to project only a bounded number of feeds.
        // A successful bounded slice must not be mistaken for a fully populated
        // PodcastCache: the next overnight run must still be scheduled.
        for expectedCachedFeeds in 1...3 {
            let result = StoreSplitFeedCacheWriter.bootstrapMissingFeedsWithStatus(
                legacyContainer: legacy,
                cacheContainer: cache,
                limit: 1
            )
            XCTAssertEqual(result.processed, 1)
            XCTAssertEqual(result.failed, 0)
            XCTAssertFalse(result.completed, "Cache backfill must keep running after a limited slice")
            XCTAssertEqual(cacheCounts(cache).podcasts, expectedCachedFeeds)
        }

        // A follow-up pass confirms that no eligible source rows remain.
        let finished = StoreSplitFeedCacheWriter.bootstrapMissingFeedsWithStatus(
            legacyContainer: legacy,
            cacheContainer: cache,
            limit: 1
        )
        XCTAssertEqual(finished.processed, 0)
        XCTAssertEqual(finished.failed, 0)
        XCTAssertTrue(finished.completed)
        XCTAssertEqual(cacheCounts(cache).episodes, 3)
    }

    @MainActor
    func testInterruptedCacheProjectionCanBeRequeuedForBackgroundRepair() throws {
        let (legacy, cache) = try makeContainers()
        let podcast = try makePodcast(
            in: legacy,
            feed: "https://example.com/cache-refresh",
            episodeGUIDs: ["first"]
        )
        let feed = try XCTUnwrap(podcast.feed)
        XCTAssertTrue(StoreSplitFeedCacheWriter.upsertFeed(
            feedURL: feed,
            legacyContainer: legacy,
            cacheContainer: cache
        ))
        let fresh = try XCTUnwrap(
            ModelContext(cache).fetch(FetchDescriptor<CachedPodcast>()).first
        )
        XCTAssertEqual(
            fresh.cacheSchemaVersion,
            StoreSplitFeedCacheWriter.currentCacheSchemaVersion
        )

        // A successful refresh normally writes straight to the cache. Only
        // an interrupted cache projection should invalidate its per-feed
        // completion marker for the charging maintenance fallback.
        XCTAssertTrue(StoreSplitFeedCacheWriter.invalidateFeedForBackgroundBootstrap(
            feedURL: feed,
            cacheContainer: cache
        ))
        let stale = try XCTUnwrap(
            ModelContext(cache).fetch(FetchDescriptor<CachedPodcast>()).first
        )
        XCTAssertEqual(stale.cacheSchemaVersion, 0)
        XCTAssertEqual(cacheCounts(cache).episodes, 1)

        let result = StoreSplitFeedCacheWriter.bootstrapMissingFeedsWithStatus(
            legacyContainer: legacy,
            cacheContainer: cache,
            limit: 10
        )
        XCTAssertEqual(result.processed, 1)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(cacheCounts(cache).episodes, 1)
        let restored = try XCTUnwrap(
            ModelContext(cache).fetch(FetchDescriptor<CachedPodcast>()).first
        )
        XCTAssertEqual(
            restored.cacheSchemaVersion,
            StoreSplitFeedCacheWriter.currentCacheSchemaVersion
        )
    }

    @MainActor
    func testPodcastCacheBackfillPausesWhenPlaybackStarts() throws {
        let (legacy, cache) = try makeContainers()
        try makePodcast(
            in: legacy,
            feed: "https://example.com/paused-during-playback",
            episodeGUIDs: ["episode-1"]
        )

        StoreSplitCachePlaybackGate.shared.setPlaybackActive(true)
        defer { StoreSplitCachePlaybackGate.shared.setPlaybackActive(false) }

        let blocked = StoreSplitFeedCacheWriter.bootstrapMissingFeedsWithStatus(
            legacyContainer: legacy,
            cacheContainer: cache,
            limit: 20,
            deadline: Date().addingTimeInterval(30)
        )
        XCTAssertFalse(blocked.completed)
        XCTAssertEqual(blocked.processed, 0)
        XCTAssertEqual(cacheCounts(cache).podcasts, 0)

        StoreSplitCachePlaybackGate.shared.setPlaybackActive(false)
        let resumed = StoreSplitFeedCacheWriter.bootstrapMissingFeedsWithStatus(
            legacyContainer: legacy,
            cacheContainer: cache,
            limit: 20
        )
        XCTAssertTrue(resumed.completed)
        XCTAssertEqual(resumed.processed, 1)
        XCTAssertEqual(cacheCounts(cache).episodes, 1)
    }

    @MainActor
    func testNormalFeedRefreshFillsMissingCacheWithoutNewEpisodes() throws {
        let (legacy, cache) = try makeContainers()
        let podcast = try makePodcast(
            in: legacy,
            feed: "https://example.com/cache-normal-refresh",
            episodeGUIDs: ["old-1", "old-2"]
        )
        // An unchanged HEAD/304 still needs to fill an empty local cache
        // from the already committed library, without another RSS download.
        XCTAssertTrue(StoreSplitFeedCacheWriter.needsFeedProjection(
            feedURL: try XCTUnwrap(podcast.feed), cacheContainer: cache
        ))
        let result = StoreSplitFeedCacheWriter.projectFeed(
            feedURL: try XCTUnwrap(podcast.feed),
            legacyContainer: legacy,
            cacheContainer: cache,
            refreshedEpisodeGUIDs: [],
            refreshedEpisodeURLs: []
        )
        XCTAssertTrue(result.completed)
        XCTAssertEqual(cacheCounts(cache).podcasts, 1)
        XCTAssertEqual(cacheCounts(cache).episodes, 2)
        XCTAssertFalse(StoreSplitFeedCacheWriter.needsFeedProjection(
            feedURL: try XCTUnwrap(podcast.feed), cacheContainer: cache
        ))
    }

    @MainActor
    func testIncrementalFeedRefreshDoesNotRescanOrDeleteUnseenEpisodes() throws {
        let (legacy, cache) = try makeContainers()
        let podcast = try makePodcast(
            in: legacy,
            feed: "https://example.com/cache-incremental-refresh",
            episodeGUIDs: ["old-1", "new-2", "old-3"]
        )
        let feed = try XCTUnwrap(podcast.feed)
        XCTAssertTrue(StoreSplitFeedCacheWriter.upsertFeed(
            feedURL: feed,
            legacyContainer: legacy,
            cacheContainer: cache
        ))

        let legacyEpisodes = try legacy.mainContext.fetch(FetchDescriptor<Episode>())
        let changed = try XCTUnwrap(legacyEpisodes.first { $0.guid == "new-2" })
        let untouched = try XCTUnwrap(legacyEpisodes.first { $0.guid == "old-1" })
        changed.title = "New title from RSS refresh"
        untouched.title = "Not present in partial RSS refresh"
        podcast.title = "Updated podcast metadata"
        try legacy.mainContext.save()

        let result = StoreSplitFeedCacheWriter.projectFeed(
            feedURL: feed,
            legacyContainer: legacy,
            cacheContainer: cache,
            refreshedEpisodeGUIDs: ["new-2"],
            refreshedEpisodeURLs: []
        )
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.deleted, 0)
        XCTAssertEqual(result.episodesProcessed, 1)
        XCTAssertEqual(cacheCounts(cache).episodes, 3)

        let context = ModelContext(cache)
        let episodes = try context.fetch(FetchDescriptor<CachedEpisode>())
        XCTAssertEqual(episodes.first { $0.guid == "new-2" }?.title, "New title from RSS refresh")
        XCTAssertEqual(episodes.first { $0.guid == "old-1" }?.title, "Title old-1")
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<CachedPodcast>()).first?.title,
            "Updated podcast metadata"
        )
    }

    @MainActor
    func testManualRefreshProjectionRecordsReadyCheckpoint() throws {
        let (legacy, cache) = try makeContainers()
        let podcast = try makePodcast(
            in: legacy,
            feed: "https://example.com/manual-cache-checkpoint",
            episodeGUIDs: ["one", "two"]
        )
        let feed = try XCTUnwrap(podcast.feed)
        let projected = StoreSplitFeedCacheWriter.projectFeed(
            feedURL: feed,
            legacyContainer: legacy,
            cacheContainer: cache,
            refreshedEpisodeGUIDs: [],
            refreshedEpisodeURLs: []
        )
        XCTAssertTrue(projected.completed)
        StoreSplitFeedCacheWriter.recordRefreshProjection(
            feedURL: feed, status: "completed",
            episodeCount: projected.episodesProcessed, cacheContainer: cache
        )

        let checkpoints = try ModelContext(cache).fetch(
            FetchDescriptor<StoreSplitFeedCacheCheckpoint>()
        )
        XCTAssertEqual(checkpoints.count, 1)
        XCTAssertEqual(checkpoints.first?.stateRawValue, "ready")
        XCTAssertEqual(cacheCounts(cache).podcasts, 1)
        XCTAssertEqual(cacheCounts(cache).episodes, 2)
    }

    @MainActor
    func testNormalFeedRefreshPopulatesEmptyCacheEvenWhilePlaying() throws {
        let (legacy, cache) = try makeContainers()
        let podcast = try makePodcast(
            in: legacy,
            feed: "https://example.com/refresh-during-playback",
            episodeGUIDs: ["episode-1", "episode-2"]
        )
        let feed = try XCTUnwrap(podcast.feed)
        StoreSplitCachePlaybackGate.shared.setPlaybackActive(true)
        defer { StoreSplitCachePlaybackGate.shared.setPlaybackActive(false) }

        // Background legacy migration is not allowed during playback, but a
        // user-initiated RSS refresh still fills its own PodcastCache records.
        let result = StoreSplitFeedCacheWriter.projectFeed(
            feedURL: feed,
            legacyContainer: legacy,
            cacheContainer: cache,
            refreshedEpisodeGUIDs: [],
            refreshedEpisodeURLs: []
        )
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.episodesProcessed, 2)
        XCTAssertEqual(cacheCounts(cache).podcasts, 1)
        XCTAssertEqual(cacheCounts(cache).episodes, 2)
    }

    @MainActor
    func testValidatedParsedFeedWritesPodcastCacheWithoutLegacyPodcast() throws {
        let (_, cache) = try makeContainers()
        let feed = try XCTUnwrap(URL(string: "https://example.com/direct-cache"))
        let rows: [[String: Any]] = [
            [
                "guid": "episode-1",
                "title": "Episode one",
                "enclosure": [["url": "https://cdn.example.com/one.mp3", "type": "audio/mpeg"]]
            ],
            [
                "guid": "episode-2",
                "title": "Episode two",
                "enclosure": [["url": "https://cdn.example.com/two.mp3", "type": "audio/mpeg"]]
            ]
        ]
        let result = StoreSplitFeedCacheWriter.projectParsedFeed(
            feedURL: feed,
            parsedFeed: ["title": "Direct cache podcast", "description": "Parsed RSS"],
            episodeRows: rows,
            isCompleteFeed: true,
            cacheContainer: cache
        )

        XCTAssertTrue(result.completed)
        XCTAssertEqual(cacheCounts(cache).podcasts, 1)
        XCTAssertEqual(cacheCounts(cache).episodes, 2)
        let context = ModelContext(cache)
        let podcast = try XCTUnwrap(context.fetch(FetchDescriptor<CachedPodcast>()).first)
        XCTAssertEqual(podcast.title, "Direct cache podcast")
        XCTAssertEqual(podcast.cacheSchemaVersion, StoreSplitFeedCacheWriter.currentCacheSchemaVersion)
    }

    @MainActor
    func testParsedFeedUsesBoundedEpisodeWriteBatches() throws {
        let (_, cache) = try makeContainers()
        let feed = try XCTUnwrap(URL(string: "https://example.com/batched-direct-cache"))
        let rows: [[String: Any]] = (0..<205).map { index in
            [
                "guid": "episode-\(index)",
                "title": "Episode \(index)",
                "enclosure": [[
                    "url": "https://cdn.example.com/\(index).mp3",
                    "type": "audio/mpeg"
                ]]
            ]
        }
        let result = StoreSplitFeedCacheWriter.projectParsedFeed(
            feedURL: feed,
            parsedFeed: ["title": "Batched podcast"],
            episodeRows: rows,
            isCompleteFeed: true,
            cacheContainer: cache
        )

        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.saveCount, 3)
        XCTAssertEqual(cacheCounts(cache).episodes, 205)
    }

    @MainActor
    func testInvalidParsedEpisodeLeavesCheckpointIncompleteAndCanRetry() throws {
        let (_, cache) = try makeContainers()
        let feed = try XCTUnwrap(URL(string: "https://example.com/invalid-direct-cache"))
        var rows: [[String: Any]] = (0..<100).map { index in
            [
                "guid": "episode-\(index)",
                "title": "Episode \(index)",
                "enclosure": [["url": "https://cdn.example.com/\(index).mp3", "type": "audio/mpeg"]]
            ]
        }
        rows.append(["guid": "invalid", "title": "Missing enclosure"])
        let first = StoreSplitFeedCacheWriter.projectParsedFeed(
            feedURL: feed, parsedFeed: ["title": "Podcast"], episodeRows: rows,
            isCompleteFeed: true, cacheContainer: cache
        )
        XCTAssertFalse(first.completed)
        XCTAssertEqual(first.failureReason, "invalid_episode_payload")
        XCTAssertEqual(cacheCounts(cache).episodes, 100)
        let partial = try XCTUnwrap(ModelContext(cache).fetch(FetchDescriptor<CachedPodcast>()).first)
        XCTAssertLessThan(partial.cacheSchemaVersion, StoreSplitFeedCacheWriter.currentCacheSchemaVersion)

        rows[100]["enclosure"] = [["url": "https://cdn.example.com/fixed.mp3", "type": "audio/mpeg"]]
        let retry = StoreSplitFeedCacheWriter.projectParsedFeed(
            feedURL: feed, parsedFeed: ["title": "Podcast"], episodeRows: rows,
            isCompleteFeed: true, cacheContainer: cache
        )
        XCTAssertTrue(retry.completed)
        XCTAssertEqual(cacheCounts(cache).episodes, 101)
        let completed = try XCTUnwrap(ModelContext(cache).fetch(FetchDescriptor<CachedPodcast>()).first)
        XCTAssertEqual(completed.cacheSchemaVersion, StoreSplitFeedCacheWriter.currentCacheSchemaVersion)

        let invalidRefresh = StoreSplitFeedCacheWriter.projectParsedFeed(
            feedURL: feed, parsedFeed: ["title": "Podcast"],
            episodeRows: [["title": "Missing enclosure"]],
            isCompleteFeed: true, cacheContainer: cache
        )
        XCTAssertFalse(invalidRefresh.completed)
        let invalidated = try XCTUnwrap(ModelContext(cache).fetch(FetchDescriptor<CachedPodcast>()).first)
        XCTAssertLessThan(invalidated.cacheSchemaVersion, StoreSplitFeedCacheWriter.currentCacheSchemaVersion)
        XCTAssertEqual(cacheCounts(cache).episodes, 101)
    }

    @MainActor
    func testPartialParsedFeedNeverPrunesOlderCacheEpisodesOrMarksFeedComplete() throws {
        let (_, cache) = try makeContainers()
        let feed = try XCTUnwrap(URL(string: "https://example.com/partial-direct-cache"))
        let initial = StoreSplitFeedCacheWriter.projectParsedFeed(
            feedURL: feed,
            parsedFeed: ["title": "Paged podcast"],
            episodeRows: [[
                "guid": "older",
                "title": "Older episode",
                "enclosure": [["url": "https://cdn.example.com/older.mp3", "type": "audio/mpeg"]]
            ]],
            isCompleteFeed: false,
            cacheContainer: cache
        )
        XCTAssertTrue(initial.completed)
        let partialCheckpoint = try XCTUnwrap(
            ModelContext(cache).fetch(FetchDescriptor<CachedPodcast>()).first
        )
        XCTAssertLessThan(partialCheckpoint.cacheSchemaVersion, StoreSplitFeedCacheWriter.currentCacheSchemaVersion)

        let partial = StoreSplitFeedCacheWriter.projectParsedFeed(
            feedURL: feed,
            parsedFeed: ["title": "Paged podcast"],
            episodeRows: [[
                "guid": "newer",
                "title": "Newer episode",
                "enclosure": [["url": "https://cdn.example.com/newer.mp3", "type": "audio/mpeg"]]
            ]],
            isCompleteFeed: false,
            cacheContainer: cache
        )

        XCTAssertTrue(partial.completed)
        XCTAssertEqual(cacheCounts(cache).episodes, 2)
        let context = ModelContext(cache)
        let podcast = try XCTUnwrap(context.fetch(FetchDescriptor<CachedPodcast>()).first)
        XCTAssertLessThan(podcast.cacheSchemaVersion, StoreSplitFeedCacheWriter.currentCacheSchemaVersion)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CachedEpisode>()).contains { $0.guid == "older" })
    }

    @MainActor
    func testMissingLegacyFeedReportsFailureRatherThanSilentEmptyCache() throws {
        let (legacy, cache) = try makeContainers()
        let feed = try XCTUnwrap(URL(string: "https://example.com/missing-cache-source"))
        let result = StoreSplitFeedCacheWriter.projectFeed(
            feedURL: feed,
            legacyContainer: legacy,
            cacheContainer: cache
        )
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.failureReason, "source_feed_not_found")
        StoreSplitFeedCacheWriter.recordRefreshProjection(
            feedURL: feed,
            status: "failed_\(result.failureReason ?? "unknown")",
            episodeCount: result.episodesProcessed,
            cacheContainer: cache
        )
        let checkpoints = try ModelContext(cache).fetch(
            FetchDescriptor<StoreSplitFeedCacheCheckpoint>()
        )
        XCTAssertEqual(checkpoints.first?.stateRawValue, "failed")
        XCTAssertEqual(cacheCounts(cache).podcasts, 0)
    }

    @MainActor
    func testCompatibilityProjectionPreservesDeviceLocalInboxMembership() throws {
        let (legacy, cache) = try makeContainers()
        let podcast = try makePodcast(
            in: legacy,
            feed: "https://example.com/inbox-state",
            episodeGUIDs: ["kept-out-of-inbox"]
        )
        let episode = try XCTUnwrap(podcast.episodes?.first)
        episode.metaData?.setInboxMembership(false)
        try legacy.mainContext.save()

        XCTAssertTrue(StoreSplitFeedCacheWriter.upsertFeed(
            feedURL: try XCTUnwrap(podcast.feed),
            legacyContainer: legacy,
            cacheContainer: cache
        ))
        let cached = try XCTUnwrap(
            ModelContext(cache).fetch(FetchDescriptor<CachedEpisode>()).first
        )
        XCTAssertFalse(cached.localIsInbox)

        let runtime = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let result = StoreSplitCompatibilityProjectionService.rebuild(
            cacheContainer: cache,
            runtimeContainer: runtime
        )
        XCTAssertEqual(result.failed, 0)
        let projected = try XCTUnwrap(
            ModelContext(runtime).fetch(FetchDescriptor<Episode>()).first
        )
        XCTAssertFalse(projected.metaData?.isInbox == true)
    }

    @MainActor
    func testLocalInboxMutationWritesDirectlyToCache() async throws {
        let (legacy, cache) = try makeContainers()
        let podcast = try makePodcast(
            in: legacy,
            feed: "https://example.com/local-inbox-mutation",
            episodeGUIDs: ["episode"]
        )
        let episode = try XCTUnwrap(podcast.episodes?.first)
        XCTAssertTrue(StoreSplitFeedCacheWriter.upsertFeed(
            feedURL: try XCTUnwrap(podcast.feed),
            legacyContainer: legacy,
            cacheContainer: cache
        ))

        await StoreSplitLocalEpisodeClassificationWriter(
            modelContainer: cache
        ).upsert([
            StoreSplitLocalEpisodeClassificationSnapshot(
                identity: episode.stableEpisodeIdentity,
                isInbox: false,
                statusRawValue: nil,
                systemSuppressionReasonRawValue:
                    EpisodeSystemSuppressionReason.backCatalogImport.rawValue
            )
        ])

        let cached = try XCTUnwrap(
            ModelContext(cache).fetch(FetchDescriptor<CachedEpisode>()).first
        )
        XCTAssertFalse(cached.localIsInbox)
        XCTAssertEqual(
            cached.localSystemSuppressionReasonRawValue,
            EpisodeSystemSuppressionReason.backCatalogImport.rawValue
        )
    }

    @MainActor
    func testPriorityPlaylistBootstrapRestoresEpisodeFromVersionedFeed() throws {
        let (legacy, cache) = try makeContainers()
        let podcast = try makePodcast(
            in: legacy,
            feed: "https://example.com/playlist-priority",
            episodeGUIDs: ["older-queued-episode"]
        )
        let feed = try XCTUnwrap(podcast.feed)
        XCTAssertTrue(StoreSplitFeedCacheWriter.upsertFeed(
            feedURL: feed,
            legacyContainer: legacy,
            cacheContainer: cache
        ))

        let cacheContext = cache.mainContext
        for episode in try cacheContext.fetch(FetchDescriptor<CachedEpisode>()) {
            cacheContext.delete(episode)
        }
        try cacheContext.save()
        XCTAssertEqual(
            StoreSplitFeedCacheWriter.bootstrapMissingFeeds(
                legacyContainer: legacy,
                cacheContainer: cache,
                limit: 10
            ),
            0,
            "A version checkpoint alone cannot detect a previously pruned queue episode"
        )

        XCTAssertEqual(
            StoreSplitFeedCacheWriter.bootstrapPriorityFeeds(
                [URL(string: "http://example.com/playlist-priority")!],
                legacyContainer: legacy,
                cacheContainer: cache
            ),
            1
        )
        XCTAssertEqual(cacheCounts(cache).episodes, 1)
    }

    @MainActor
    func testPriorityRecoveryIncludesQueuePlaylistsBookmarksAndRecentPlayback() throws {
        let userState = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let context = userState.mainContext
        let now = Date()
        let queueFeed = "https://example.com/queue-priority"
        let playlistFeed = "https://example.com/playlist-priority"
        let bookmarkFeed = "https://example.com/bookmark-priority"
        let recentFeed = "https://example.com/recent-priority"
        context.insert(QueueEntrySync(
            feedURL: queueFeed,
            episodeID: "queue-episode",
            sortIndex: 0,
            updatedAt: now
        ))
        context.insert(PlaylistEntrySync(
            playlistID: "custom",
            feedURL: playlistFeed,
            episodeID: "playlist-episode",
            sortIndex: 0,
            updatedAt: now
        ))
        context.insert(BookmarkSync(
            feedURL: bookmarkFeed,
            episodeID: "bookmark-episode",
            time: 12,
            createdAt: now,
            updatedAt: now
        ))
        context.insert(EpisodeStateSync(
            feedURL: recentFeed,
            episodeID: "recent-episode",
            playPosition: 20,
            lastPlayedAt: now,
            updatedAt: now
        ))
        try context.save()

        let result = ModelContainerManager.shared.priorityRecoveryFeedURLs(
            userState,
            after: nil,
            limit: 10
        )
        XCTAssertTrue(result.reachedEnd)
        XCTAssertEqual(Set(result.feeds.map(PodcastFeedIdentity.normalizedFeedURLString)), Set([
            PodcastFeedIdentity.normalizedFeedURLString(URL(string: queueFeed)!),
            PodcastFeedIdentity.normalizedFeedURLString(URL(string: playlistFeed)!),
            PodcastFeedIdentity.normalizedFeedURLString(URL(string: bookmarkFeed)!),
            PodcastFeedIdentity.normalizedFeedURLString(URL(string: recentFeed)!)
        ]))
    }

    @MainActor
    func testProjectionIsIdempotentAndFetchCountDoesNotScaleWithEpisodes() throws {
        let (legacy, cache) = try makeContainers()
        let feed = "https://example.com/scale"
        let podcast = try makePodcast(
            in: legacy,
            feed: feed,
            episodeGUIDs: (0..<500).map { "episode-\($0)" }
        )

        let first = StoreSplitFeedCacheWriter.projectFeed(
            feedURL: try XCTUnwrap(podcast.feed),
            legacyContainer: legacy,
            cacheContainer: cache
        )
        XCTAssertTrue(first.completed)
        XCTAssertEqual(first.episodesProcessed, 500)
        // Alias-aware indexed lookup adds one bounded fallback query while
        // preserving feed-scoped work regardless of episode population.
        XCTAssertLessThanOrEqual(first.fetchCount, 9)
        XCTAssertEqual(first.saveCount, 1)

        let second = StoreSplitFeedCacheWriter.projectFeed(
            feedURL: try XCTUnwrap(podcast.feed),
            legacyContainer: legacy,
            cacheContainer: cache
        )
        XCTAssertTrue(second.completed)
        XCTAssertEqual(second.fetchCount, first.fetchCount)
        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.updated, 0)
        XCTAssertEqual(second.deleted, 0)
        XCTAssertEqual(second.saveCount, 0)
        XCTAssertEqual(second.episodesUnchanged, 500)
    }

    @MainActor
    func testProjectionChangesOnlyTheModifiedEpisode() throws {
        let (legacy, cache) = try makeContainers()
        let podcast = try makePodcast(
            in: legacy,
            feed: "https://example.com/incremental",
            episodeGUIDs: (0..<20).map { "episode-\($0)" }
        )
        let feed = try XCTUnwrap(podcast.feed)
        _ = StoreSplitFeedCacheWriter.projectFeed(
            feedURL: feed,
            legacyContainer: legacy,
            cacheContainer: cache
        )

        let legacyContext = legacy.mainContext
        let changedEpisode = try XCTUnwrap(podcast.episodes?.first)
        changedEpisode.title = "Changed"
        try legacyContext.save()

        let result = StoreSplitFeedCacheWriter.projectFeed(
            feedURL: feed,
            legacyContainer: legacy,
            cacheContainer: cache
        )
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.inserted, 0)
        XCTAssertEqual(result.deleted, 0)
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.episodesUnchanged, 19)
        XCTAssertEqual(result.saveCount, 1)
    }

    @MainActor
    func testLargeProjectionKeepsFetchesFeedScoped() throws {
        let (legacy, cache) = try makeContainers()
        let podcast = try makePodcast(
            in: legacy,
            feed: "https://example.com/large-scale",
            episodeGUIDs: (0..<2_000).map { "episode-\($0)" }
        )

        let result = StoreSplitFeedCacheWriter.projectFeed(
            feedURL: try XCTUnwrap(podcast.feed),
            legacyContainer: legacy,
            cacheContainer: cache
        )

        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.episodesProcessed, 2_000)
        XCTAssertLessThanOrEqual(result.fetchCount, 9)
        XCTAssertEqual(result.saveCount, 1)
    }

    @MainActor
    func testBootstrapUpgradesAnExistingPhaseTwoCacheProjectionOnce() throws {
        let (legacy, cache) = try makeContainers()
        try makePodcast(in: legacy, feed: "https://example.com/upgrade", episodeGUIDs: ["e1"])

        XCTAssertEqual(
            StoreSplitFeedCacheWriter.bootstrapMissingFeeds(
                legacyContainer: legacy,
                cacheContainer: cache,
                limit: 10
            ),
            1
        )

        let context = cache.mainContext
        let cachedPodcast = try XCTUnwrap(
            context.fetch(FetchDescriptor<CachedPodcast>()).first
        )
        cachedPodcast.cacheSchemaVersion = 1
        try context.save()

        XCTAssertEqual(
            StoreSplitFeedCacheWriter.bootstrapMissingFeeds(
                legacyContainer: legacy,
                cacheContainer: cache,
                limit: 10
            ),
            1
        )
        let verification = ModelContext(cache)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<CachedPodcast>()).first?.cacheSchemaVersion,
            StoreSplitFeedCacheWriter.currentCacheSchemaVersion
        )
        XCTAssertEqual(
            StoreSplitFeedCacheWriter.bootstrapMissingFeeds(
                legacyContainer: legacy,
                cacheContainer: cache,
                limit: 10
            ),
            0
        )
    }

    @MainActor
    func testExpiredDeadlineDoesNotCommitPartialCacheProjection() throws {
        let (legacy, cache) = try makeContainers()
        let podcast = try makePodcast(
            in: legacy,
            feed: "https://example.com/deadline",
            episodeGUIDs: ["e1", "e2"]
        )

        XCTAssertFalse(
            StoreSplitFeedCacheWriter.upsertFeed(
                feedURL: try XCTUnwrap(podcast.feed),
                legacyContainer: legacy,
                cacheContainer: cache,
                deadline: .distantPast
            )
        )

        let verification = ModelContext(cache)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<CachedPodcast>()), 0)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<CachedEpisode>()), 0)
        XCTAssertEqual(
            try verification.fetchCount(FetchDescriptor<CachedDownloadRecord>()),
            0
        )
    }

    @MainActor
    func testUpsertCopiesPhaseThreeSupplementalCacheData() throws {
        let (legacy, cache) = try makeContainers()
        let podcast = try makePodcast(
            in: legacy,
            feed: "https://example.com/details",
            episodeGUIDs: ["e1"]
        )
        let context = legacy.mainContext
        let episode = try XCTUnwrap(podcast.episodes?.first)

        let chapter = Marker(
            start: 12,
            title: "Introduction",
            type: .podlove,
            duration: 30
        )
        chapter.episode = episode
        episode.chapters = [chapter]
        context.insert(chapter)

        let line = TranscriptLineAndTime(
            speaker: "Host",
            text: "Welcome",
            startTime: 1.5,
            endTime: 3
        )
        line.episode = episode
        episode.transcriptLines = [line]
        context.insert(line)

        context.insert(
            TranscriptionRecord(
                episodeURL: try XCTUnwrap(episode.url),
                episodeTitle: episode.title,
                podcastTitle: podcast.title,
                localeIdentifier: "en_US",
                startedAt: Date(timeIntervalSince1970: 10),
                finishedAt: Date(timeIntervalSince1970: 20),
                audioDuration: 120
            )
        )
        try context.save()
        let projection = StoreSplitFeedCacheWriter.projectFeed(
            feedURL: try XCTUnwrap(podcast.feed),
            legacyContainer: legacy,
            cacheContainer: cache
        )
        XCTAssertTrue(projection.completed)
        XCTAssertEqual(projection.chaptersProcessed, 1, "projected chapters")
        XCTAssertEqual(projection.transcriptLinesProcessed, 1, "projected transcript lines")
        XCTAssertEqual(projection.transcriptionRecordsProcessed, 1, "projected transcription records")

        let verification = ModelContext(cache)
        let cachedPodcast = try XCTUnwrap(
            verification.fetch(FetchDescriptor<CachedPodcast>()).first
        )
        XCTAssertEqual(cachedPodcast.cacheSchemaVersion, StoreSplitFeedCacheWriter.currentCacheSchemaVersion)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<CachedChapter>()), 1)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<CachedTranscriptLine>()), 1)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<CachedTranscriptionRecord>()), 1)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<CachedDownloadRecord>()), 1)

        let cachedChapter = try XCTUnwrap(
            verification.fetch(FetchDescriptor<CachedChapter>()).first
        )
        XCTAssertEqual(cachedChapter.title, "Introduction")
        XCTAssertEqual(cachedChapter.typeRawValue, MarkerType.podlove.rawValue)
        let cachedLine = try XCTUnwrap(
            verification.fetch(FetchDescriptor<CachedTranscriptLine>()).first
        )
        XCTAssertEqual(cachedLine.speaker, "Host")
        XCTAssertEqual(cachedLine.text, "Welcome")
    }

    @MainActor
    func testFeedAliasUpsertIsNormalizedAndIdempotent() throws {
        let (_, cache) = try makeContainers()
        let oldURL = URL(string: "HTTPS://Example.COM:443/feed#old")!
        let newURL = URL(string: "https://example.com/new-feed")!

        StoreSplitFeedCacheWriter.upsertFeedAlias(
            from: oldURL,
            to: newURL,
            reason: .permanentRedirect,
            cacheContainer: cache
        )
        StoreSplitFeedCacheWriter.upsertFeedAlias(
            from: oldURL,
            to: newURL,
            reason: .explicitSwitch,
            cacheContainer: cache
        )

        let context = ModelContext(cache)
        let aliases = try context.fetch(FetchDescriptor<FeedAlias>())
        XCTAssertEqual(aliases.count, 1)
        XCTAssertEqual(aliases[0].oldFeedURL, "https://example.com/feed")
        XCTAssertEqual(aliases[0].newFeedURL, "https://example.com/new-feed")
        XCTAssertEqual(aliases[0].reasonRawValue, FeedAliasReason.explicitSwitch.rawValue)
    }

    @MainActor
    func testFullProjectionPreservesHistoricalEpisodeAndContent() async throws {
        let (legacy, cache) = try makeContainers()
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let feed = "https://example.com/b"
        let podcast = try makePodcast(in: legacy, feed: feed, episodeGUIDs: ["e1", "e2", "e3"])

        StoreSplitFeedCacheWriter.upsertFeed(
            feedURL: podcast.feed!, legacyContainer: legacy, cacheContainer: cache
        )
        XCTAssertEqual(cacheCounts(cache).episodes, 3)

        let cacheContext = ModelContext(cache)
        let historical = try XCTUnwrap(cacheContext.fetch(FetchDescriptor<CachedEpisode>()).first { $0.guid == "e2" })
        let identity = EpisodeStableIdentity(feedURL: historical.feedURL, episodeID: historical.episodeID)
        cacheContext.insert(CachedChapter(id: "old-chapter", feedURL: historical.feedURL, episodeID: historical.id, title: "Chapter"))
        cacheContext.insert(CachedTranscriptLine(id: "old-line", feedURL: historical.feedURL, episodeID: historical.id, text: "Transcript"))
        try cacheContext.save()
        userState.mainContext.insert(QueueEntrySync(feedURL: identity.feedURL, episodeID: identity.episodeID, sortIndex: 0))
        try userState.mainContext.save()

        // Remove one episode from the legacy feed, then re-run the dual-write.
        let context = legacy.mainContext
        if let toDelete = podcast.episodes?.first(where: { $0.guid == "e2" }) {
            context.delete(toDelete)
        }
        try context.save()

        StoreSplitFeedCacheWriter.upsertFeed(
            feedURL: podcast.feed!, legacyContainer: legacy, cacheContainer: cache
        )
        let counts = cacheCounts(cache)
        XCTAssertEqual(counts.podcasts, 1)
        XCTAssertEqual(counts.episodes, 3)
        XCTAssertEqual(
            try ModelContext(cache).fetchCount(FetchDescriptor<CachedDownloadRecord>()),
            3
        )
        XCTAssertEqual(try ModelContext(cache).fetchCount(FetchDescriptor<CachedChapter>()), 1)
        XCTAssertEqual(try ModelContext(cache).fetchCount(FetchDescriptor<CachedTranscriptLine>()), 1)
        let repository = PodcastCacheRepository(cacheContainer: cache, userStateContainer: userState)
        let restored = await repository.episode(identity: identity)
        XCTAssertEqual(restored?.title, "Title e2")
        XCTAssertEqual(restored?.chapters.first?.title, "Chapter")
        XCTAssertEqual(restored?.transcript.first?.text, "Transcript")
    }
}
