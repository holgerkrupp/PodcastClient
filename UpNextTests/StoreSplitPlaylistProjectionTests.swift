import SwiftData
import XCTest
@testable import UpNext

final class StoreSplitPlaylistProjectionTests: XCTestCase {
    @MainActor
    func testUpgradeKeepsQueueVisibleWithoutPuttingEntireFeedInInbox() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let cache = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let runtime = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let feed = URL(string: "https://example.com/seamless-upgrade")!
        let podcast = Podcast(feed: feed)
        var episodes: [Episode] = []
        for index in 0..<20 {
            let episode = Episode(
                guid: "episode-\(index)",
                title: "Episode \(index)",
                url: URL(string: "https://example.com/episode-\(index).mp3")!,
                podcast: podcast
            )
            episode.metaData?.setInboxMembership(index < 2)
            episodes.append(episode)
            legacy.mainContext.insert(episode)
        }
        podcast.episodes = episodes
        let queue = Playlist()
        queue.items = Array(episodes.prefix(12).enumerated()).map { index, episode in
            let entry = PlaylistEntry(episode: episode, order: index)
            entry.playlist = queue
            legacy.mainContext.insert(entry)
            return entry
        }
        legacy.mainContext.insert(podcast)
        legacy.mainContext.insert(queue)
        try legacy.mainContext.save()

        let repair = await StoreSplitPlaylistRepairService.repair(
            legacyContainer: legacy,
            userStateContainer: userState
        )
        XCTAssertTrue(repair.isComplete)
        XCTAssertEqual(repair.queueEntryCount, 12)
        XCTAssertEqual(StoreSplitFeedCacheWriter.bootstrapPriorityFeeds(
            [feed],
            legacyContainer: legacy,
            cacheContainer: cache
        ), 1)
        XCTAssertEqual(
            StoreSplitCompatibilityProjectionService.rebuild(
                cacheContainer: cache,
                runtimeContainer: runtime
            ).failed,
            0
        )

        _ = await StoreSplitUserStateImporter.apply(
            legacyContainer: runtime,
            userStateContainer: userState,
            authoritativePlaylists: true
        )
        let context = ModelContext(runtime)
        let projectedQueue = try XCTUnwrap(
            context.fetch(FetchDescriptor<Playlist>())
                .first { $0.title == Playlist.defaultQueueTitle }
        )
        XCTAssertEqual(projectedQueue.ordered.count, 12)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<EpisodeMetaData>(
                predicate: #Predicate { $0.isInbox == true }
            )),
            2
        )
    }

    func testSilentPlaylistRecoveryRequiresARealPlaylistReference() {
        XCTAssertFalse(PlaylistSilentRecoveryDecision.shouldReconcile(
            initializationError: nil,
            localRecordCount: 0,
            cloudReferenceCount: 0,
            didRequestAutomaticReconcile: false
        ))

        XCTAssertTrue(
            PlaylistSilentRecoveryDecision.shouldReconcile(
                initializationError: nil,
                localRecordCount: 0,
                cloudReferenceCount: 4,
                didRequestAutomaticReconcile: false
            )
        )
        XCTAssertFalse(PlaylistSilentRecoveryDecision.shouldReconcile(
            initializationError: nil,
            localRecordCount: 4,
            cloudReferenceCount: nil,
            didRequestAutomaticReconcile: true
        ))
    }

    @MainActor
    func testDefaultQueueUsesTheSameSplitStoreIdentityOnEveryDevice() {
        let firstQueue = Playlist()
        firstQueue.id = UUID()
        firstQueue.syncID = firstQueue.id.uuidString

        let secondQueue = Playlist()
        secondQueue.id = UUID()
        secondQueue.syncID = secondQueue.id.uuidString

        XCTAssertNotEqual(firstQueue.id, secondQueue.id)
        XCTAssertEqual(firstQueue.storeSplitSnapshot.id, Playlist.defaultQueueSyncID)
        XCTAssertEqual(secondQueue.storeSplitSnapshot.id, Playlist.defaultQueueSyncID)
    }

    @MainActor
    func testImportedPlaylistRetainsItsCloudIdentityWhenRepublished() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let localPlaylist = Playlist()
        localPlaylist.title = "Commute"
        localPlaylist.deleteable = true
        legacy.mainContext.insert(localPlaylist)

        let cloudID = UUID().uuidString
        userState.mainContext.insert(
            PlaylistSync(
                id: cloudID,
                title: "Commute",
                symbolName: Playlist.defaultManualSymbolName,
                sortIndex: 1,
                kindRawValue: Playlist.Kind.manual.rawValue
            )
        )
        try legacy.mainContext.save()
        try userState.mainContext.save()

        _ = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacy,
            userStateContainer: userState
        )

        let context = ModelContext(legacy)
        let imported = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Playlist>())
                .first { $0.title == "Commute" }
        )
        XCTAssertNotEqual(imported.id.uuidString, cloudID)
        XCTAssertEqual(imported.syncID, cloudID)
        XCTAssertEqual(imported.storeSplitSnapshot.id, cloudID)
    }

    @MainActor
    func testLegacyPlaylistRepairBackfillsQueueIntoUserStateStore() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let episode = Episode(
            guid: "legacy-queue-entry",
            title: "Legacy queue entry",
            url: URL(string: "https://example.com/legacy.mp3")!,
            podcast: podcast
        )
        podcast.episodes = [episode]
        let queue = Playlist()
        let entry = PlaylistEntry(episode: episode, order: 0)
        entry.playlist = queue
        queue.items = [entry]
        legacy.mainContext.insert(podcast)
        legacy.mainContext.insert(queue)
        legacy.mainContext.insert(entry)
        try legacy.mainContext.save()

        let result = await StoreSplitPlaylistRepairService.repair(
            legacyContainer: legacy,
            userStateContainer: userState
        )

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.playlistCount, 1)
        XCTAssertEqual(result.playlistEntryCount, 1)
        XCTAssertEqual(result.queueEntryCount, 1)

        let context = ModelContext(userState)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlaylistSync>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlaylistEntrySync>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueEntrySync>()), 1)

        _ = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacy,
            userStateContainer: userState
        )
        let projectedQueue = try XCTUnwrap(
            try ModelContext(legacy).fetch(FetchDescriptor<Playlist>())
                .first { $0.title == Playlist.defaultQueueTitle }
        )
        XCTAssertEqual(projectedQueue.ordered.first?.episode?.guid, "legacy-queue-entry")
    }

    @MainActor
    func testDefaultQueueMergesEntriesFromDifferentDevicePlaylistIDs() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let olderEpisode = Episode(
            guid: "older-device-entry",
            title: "Older device",
            url: URL(string: "https://example.com/older.mp3")!,
            podcast: podcast
        )
        let newerEpisode = Episode(
            guid: "newer-device-entry",
            title: "Newer device",
            url: URL(string: "https://example.com/newer.mp3")!,
            podcast: podcast
        )
        podcast.episodes = [olderEpisode, newerEpisode]
        let localQueue = Playlist()
        legacy.mainContext.insert(podcast)
        legacy.mainContext.insert(localQueue)

        let olderPlaylistID = UUID().uuidString
        let newerPlaylistID = UUID().uuidString
        userState.mainContext.insert(
            PlaylistSync(
                id: olderPlaylistID,
                title: Playlist.defaultQueueTitle,
                symbolName: Playlist.defaultQueueSymbolName,
                sortIndex: 0,
                kindRawValue: Playlist.Kind.manual.rawValue,
                updatedAt: Date(timeIntervalSince1970: 1_000)
            )
        )
        userState.mainContext.insert(
            PlaylistSync(
                id: newerPlaylistID,
                title: Playlist.defaultQueueTitle,
                symbolName: Playlist.defaultQueueSymbolName,
                sortIndex: 0,
                kindRawValue: Playlist.Kind.manual.rawValue,
                updatedAt: Date(timeIntervalSince1970: 2_000)
            )
        )
        for (playlistID, episode, order) in [
            (olderPlaylistID, olderEpisode, 0),
            (newerPlaylistID, newerEpisode, 1)
        ] {
            let identity = episode.stableEpisodeIdentity
            userState.mainContext.insert(
                PlaylistEntrySync(
                    playlistID: playlistID,
                    feedURL: identity.feedURL,
                    episodeID: identity.episodeID,
                    sortIndex: order
                )
            )
        }
        try legacy.mainContext.save()
        try userState.mainContext.save()

        _ = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacy,
            userStateContainer: userState,
            authoritativePlaylists: true
        )

        let context = ModelContext(legacy)
        let queue = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Playlist>())
                .first { $0.title == Playlist.defaultQueueTitle }
        )
        XCTAssertEqual(
            Set(queue.ordered.compactMap { $0.episode?.guid }),
            Set(["older-device-entry", "newer-device-entry"])
        )
    }

    @MainActor
    func testQueueOnlySplitRecordsProjectIntoDefaultQueue() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let episode = Episode(
            guid: "queue-only-entry",
            title: "Queue only",
            url: URL(string: "https://example.com/queue-only.mp3")!,
            podcast: podcast
        )
        podcast.episodes = [episode]
        legacy.mainContext.insert(podcast)
        legacy.mainContext.insert(Playlist())

        let identity = episode.stableEpisodeIdentity
        userState.mainContext.insert(
            QueueEntrySync(
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                sortIndex: 0
            )
        )
        try legacy.mainContext.save()
        try userState.mainContext.save()

        let result = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacy,
            userStateContainer: userState
        )

        let context = ModelContext(legacy)
        let queue = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Playlist>())
                .first { $0.title == Playlist.defaultQueueTitle }
        )
        XCTAssertEqual(result.playlistEntriesApplied, 1)
        XCTAssertEqual(queue.ordered.first?.episode?.guid, "queue-only-entry")
    }

    @MainActor
    func testMissingPlaylistFeedsArePrioritizedForBootstrap() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        legacy.mainContext.insert(Playlist())

        let playlistFeed = "https://example.com/playlist-feed.xml"
        let stateFeed = "https://example.com/state-feed.xml"
        userState.mainContext.insert(
            PlaylistSync(
                id: Playlist.defaultQueueSyncID,
                title: Playlist.defaultQueueTitle,
                symbolName: Playlist.defaultQueueSymbolName,
                sortIndex: 0,
                kindRawValue: Playlist.Kind.manual.rawValue
            )
        )
        userState.mainContext.insert(
            PlaylistEntrySync(
                playlistID: Playlist.defaultQueueSyncID,
                feedURL: playlistFeed,
                episodeID: "missing-playlist-episode",
                sortIndex: 0
            )
        )
        userState.mainContext.insert(
            EpisodeStateSync(
                feedURL: stateFeed,
                episodeID: "missing-state-episode"
            )
        )
        try legacy.mainContext.save()
        try userState.mainContext.save()

        let result = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacy,
            userStateContainer: userState
        )

        XCTAssertEqual(
            result.playlistFeedsToBootstrap.map(\.absoluteString),
            [playlistFeed]
        )
        XCTAssertEqual(
            Set(result.feedsToBootstrap.map(\.absoluteString)),
            Set([playlistFeed, stateFeed])
        )
    }

    @MainActor
    func testNewerQueueTombstoneWinsOverAnOldPlaylistAlias() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let episode = Episode(
            guid: "removed-on-other-device",
            title: "Removed",
            url: URL(string: "https://example.com/removed.mp3")!,
            podcast: podcast
        )
        podcast.episodes = [episode]
        let queue = Playlist()
        let localEntry = PlaylistEntry(episode: episode, order: 0)
        localEntry.playlist = queue
        queue.items = [localEntry]
        legacy.mainContext.insert(podcast)
        legacy.mainContext.insert(queue)
        legacy.mainContext.insert(localEntry)

        let oldAliasID = UUID().uuidString
        for playlistID in [oldAliasID, Playlist.defaultQueueSyncID] {
            userState.mainContext.insert(
                PlaylistSync(
                    id: playlistID,
                    title: Playlist.defaultQueueTitle,
                    symbolName: Playlist.defaultQueueSymbolName,
                    sortIndex: 0,
                    kindRawValue: Playlist.Kind.manual.rawValue
                )
            )
        }
        let identity = episode.stableEpisodeIdentity
        userState.mainContext.insert(
            PlaylistEntrySync(
                playlistID: oldAliasID,
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                sortIndex: 0,
                updatedAt: Date(timeIntervalSince1970: 1_000)
            )
        )
        userState.mainContext.insert(
            QueueEntrySync(
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                sortIndex: 0,
                isDeleted: true,
                deletedAt: Date(timeIntervalSince1970: 2_000),
                updatedAt: Date(timeIntervalSince1970: 2_000)
            )
        )
        try legacy.mainContext.save()
        try userState.mainContext.save()

        _ = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacy,
            userStateContainer: userState,
            authoritativePlaylists: true
        )

        let context = ModelContext(legacy)
        let projectedQueue = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Playlist>())
                .first { $0.title == Playlist.defaultQueueTitle }
        )
        XCTAssertTrue(projectedQueue.ordered.isEmpty)
    }

    @MainActor
    func testStalePublishDoesNotReviveANewerRemoval() async throws {
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let identity = EpisodeStableIdentity(
            feedURL: "https://example.com/feed.xml",
            episodeID: "finished-episode"
        )
        let addedAt = Date(timeIntervalSince1970: 1_000)
        let removedAt = Date(timeIntervalSince1970: 2_000)

        let writer = StoreSplitPlaylistSyncWriter(modelContainer: userState)
        await writer.tombstone(
            [
                StoreSplitPlaylistRemoval(
                    playlistID: Playlist.defaultQueueSyncID,
                    isDefaultQueue: true,
                    identity: identity
                )
            ],
            at: removedAt
        )

        // A device whose local queue still holds the finished episode republishes
        // its whole playlist. That projection predates the removal, so it must not
        // clear the tombstone.
        await writer.upsert(
            StoreSplitPlaylistSnapshot(
                id: Playlist.defaultQueueSyncID,
                title: Playlist.defaultQueueTitle,
                symbolName: Playlist.defaultQueueSymbolName,
                sortIndex: 0,
                kindRawValue: Playlist.Kind.manual.rawValue,
                smartFilterRawValue: nil,
                isHidden: false,
                entries: [
                    StoreSplitPlaylistEntrySnapshot(
                        identity: identity,
                        sortIndex: 0,
                        addedAt: addedAt
                    )
                ]
            ),
            at: Date(timeIntervalSince1970: 3_000)
        )

        let context = ModelContext(userState)
        let playlistEntries = try context.fetch(FetchDescriptor<PlaylistEntrySync>())
        let queueEntries = try context.fetch(FetchDescriptor<QueueEntrySync>())
        XCTAssertEqual(playlistEntries.count, 1)
        XCTAssertEqual(queueEntries.count, 1)
        XCTAssertTrue(try XCTUnwrap(playlistEntries.first).isDeleted)
        XCTAssertTrue(try XCTUnwrap(queueEntries.first).isDeleted)
    }

    @MainActor
    func testDeliberateRelistenRevivesTheRemovedEntry() async throws {
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let identity = EpisodeStableIdentity(
            feedURL: "https://example.com/feed.xml",
            episodeID: "replayed-episode"
        )

        let writer = StoreSplitPlaylistSyncWriter(modelContainer: userState)
        await writer.tombstone(
            [
                StoreSplitPlaylistRemoval(
                    playlistID: Playlist.defaultQueueSyncID,
                    isDefaultQueue: true,
                    identity: identity
                )
            ],
            at: Date(timeIntervalSince1970: 2_000)
        )
        await writer.upsert(
            StoreSplitPlaylistSnapshot(
                id: Playlist.defaultQueueSyncID,
                title: Playlist.defaultQueueTitle,
                symbolName: Playlist.defaultQueueSymbolName,
                sortIndex: 0,
                kindRawValue: Playlist.Kind.manual.rawValue,
                smartFilterRawValue: nil,
                isHidden: false,
                entries: [
                    StoreSplitPlaylistEntrySnapshot(
                        identity: identity,
                        sortIndex: 0,
                        addedAt: Date(timeIntervalSince1970: 3_000)
                    )
                ]
            ),
            at: Date(timeIntervalSince1970: 3_000)
        )

        let context = ModelContext(userState)
        let playlistEntries = try context.fetch(FetchDescriptor<PlaylistEntrySync>())
        let queueEntries = try context.fetch(FetchDescriptor<QueueEntrySync>())
        XCTAssertFalse(try XCTUnwrap(playlistEntries.first).isDeleted)
        XCTAssertFalse(try XCTUnwrap(queueEntries.first).isDeleted)
    }

    @MainActor
    func testImportDoesNotRequeueAnEpisodeThatWasAlreadyPlayed() async throws {
        // The played-episode queue rule ships disabled; enable it to cover it.
        UserDefaults.standard.set(
            true,
            forKey: PlayedEpisodePlaylistPruner.isEnabledKey
        )
        defer {
            UserDefaults.standard.removeObject(
                forKey: PlayedEpisodePlaylistPruner.isEnabledKey
            )
        }
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let playedEpisode = Episode(
            guid: "finished-elsewhere",
            title: "Finished",
            url: URL(string: "https://example.com/finished.mp3")!,
            podcast: podcast
        )
        playedEpisode.metaData?.completionDate = Date(timeIntervalSince1970: 5_000)
        podcast.episodes = [playedEpisode]
        legacy.mainContext.insert(podcast)
        legacy.mainContext.insert(Playlist())

        let identity = playedEpisode.stableEpisodeIdentity
        userState.mainContext.insert(
            PlaylistSync(
                id: Playlist.defaultQueueSyncID,
                title: Playlist.defaultQueueTitle,
                symbolName: Playlist.defaultQueueSymbolName,
                sortIndex: 0,
                kindRawValue: Playlist.Kind.manual.rawValue
            )
        )
        // Authored before the episode was finished, so it is stale queue state
        // rather than a deliberate re-listen.
        userState.mainContext.insert(
            PlaylistEntrySync(
                playlistID: Playlist.defaultQueueSyncID,
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                sortIndex: 0,
                addedAt: Date(timeIntervalSince1970: 1_000),
                updatedAt: Date(timeIntervalSince1970: 1_000)
            )
        )
        userState.mainContext.insert(
            QueueEntrySync(
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                sortIndex: 0,
                addedAt: Date(timeIntervalSince1970: 1_000),
                updatedAt: Date(timeIntervalSince1970: 1_000)
            )
        )
        try legacy.mainContext.save()
        try userState.mainContext.save()

        _ = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacy,
            userStateContainer: userState
        )

        let context = ModelContext(legacy)
        let queue = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Playlist>())
                .first { $0.title == Playlist.defaultQueueTitle }
        )
        XCTAssertTrue(queue.ordered.isEmpty)
    }
}
