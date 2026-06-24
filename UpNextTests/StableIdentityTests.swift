import SwiftData
import XCTest
@testable import UpNext

final class StableIdentityTests: XCTestCase {
    func testSplitStoreReadModeSupportsCloudBackedDualWriteMigration() {
        let configuration = StoreDevelopmentConfiguration(
            mode: .splitStoreReads,
            legacyCloudSyncEnabled: true,
            userStateCloudSyncEnabled: true,
            splitStoreWorkEnabled: true
        )

        XCTAssertTrue(configuration.splitStoresEnabled)
        XCTAssertTrue(configuration.newStoreReadsEnabled)
        XCTAssertTrue(configuration.legacyMigrationEnabled)
        XCTAssertTrue(configuration.effectiveLegacyCloudSyncEnabled)
        XCTAssertTrue(configuration.effectiveUserStateCloudSyncEnabled)
    }

    func testSplitStoreWorkSwitchPausesMigrationAndProjection() {
        let configuration = StoreDevelopmentConfiguration(
            mode: .splitStoreReads,
            legacyCloudSyncEnabled: true,
            userStateCloudSyncEnabled: true,
            splitStoreWorkEnabled: false
        )

        XCTAssertFalse(configuration.splitStoresEnabled)
        XCTAssertFalse(configuration.newStoreReadsEnabled)
        XCTAssertFalse(configuration.legacyMigrationEnabled)
        XCTAssertTrue(configuration.effectiveLegacyCloudSyncEnabled)
        XCTAssertTrue(configuration.effectiveUserStateCloudSyncEnabled)
    }

    func testEpisodeIdentityPrefersGUIDWithinFeed() {
        let feedURL = URL(string: "https://example.com/podcast.xml")!
        let identity = EpisodeStableIdentity.make(
            feedURL: feedURL,
            episodeGUID: "episode-123",
            enclosureURL: URL(string: "https://cdn.example.com/audio.mp3")!,
            episodeURL: URL(string: "https://cdn.example.com/audio.mp3")!,
            linkURL: URL(string: "https://example.com/episode")!
        )

        XCTAssertEqual(identity.feedURL, PodcastFeedIdentity.normalizedFeedURLString(feedURL))
        XCTAssertEqual(identity.episodeID, "guid:episode-123")
        XCTAssertEqual(
            identity.key,
            StableIdentityKey.make(
                PodcastFeedIdentity.normalizedFeedURLString(feedURL),
                "guid:episode-123"
            )
        )
    }

    func testEpisodeIdentityFallsBackToEnclosureURLWhenGUIDMissing() {
        let identity = EpisodeStableIdentity.make(
            feedURL: URL(string: "https://example.com/podcast.xml")!,
            episodeGUID: nil,
            enclosureURL: URL(string: "https://cdn.example.com/audio.mp3")!,
            episodeURL: URL(string: "https://cdn.example.com/audio.mp3")!,
            linkURL: nil
        )

        XCTAssertEqual(identity.episodeID, "enclosure:https://cdn.example.com/audio.mp3")
    }

    func testEpisodeIdentityFallsBackToHashWhenAllIdentifiersMissing() {
        let identity = EpisodeStableIdentity.make(
            feedURL: URL(string: "https://example.com/podcast.xml")!,
            episodeGUID: nil,
            enclosureURL: nil,
            episodeURL: nil,
            linkURL: nil
        )

        XCTAssertEqual(identity.feedURL, PodcastFeedIdentity.normalizedFeedURLString(URL(string: "https://example.com/podcast.xml")!))
        XCTAssertTrue(identity.episodeID.hasPrefix("hash:"))
        XCTAssertEqual(identity.episodeID.count, 69)
    }

    func testHashFallbackUsesTitleAndPublicationDate() {
        let feedURL = URL(string: "https://example.com/podcast.xml")!
        let first = EpisodeStableIdentity.make(
            feedURL: feedURL,
            episodeGUID: nil,
            enclosureURL: nil,
            episodeURL: nil,
            linkURL: nil,
            title: "Episode One",
            publishDate: Date(timeIntervalSince1970: 1_000)
        )
        let second = EpisodeStableIdentity.make(
            feedURL: feedURL,
            episodeGUID: nil,
            enclosureURL: nil,
            episodeURL: nil,
            linkURL: nil,
            title: "Episode Two",
            publishDate: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertNotEqual(first.episodeID, second.episodeID)
    }

    func testURLNormalizationRemovesFragmentAndDefaultPort() {
        let url = URL(string: "HTTPS://Example.COM:443/podcast.xml?edition=full#section")!

        XCTAssertEqual(
            PodcastFeedIdentity.normalizedFeedURLString(url),
            "https://example.com/podcast.xml?edition=full"
        )
    }

    func testCompositeKeyDoesNotCollideWhenComponentsContainSeparators() {
        XCTAssertNotEqual(
            StableIdentityKey.make("feed|episode", "id"),
            StableIdentityKey.make("feed", "episode|id")
        )
    }

    @MainActor
    func testSubscriptionWriterCreatesDeletionTombstone() async throws {
        let container = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let feedURL = URL(string: "HTTPS://Example.com:443/feed.xml#fragment")!
        let deletionDate = Date(timeIntervalSince1970: 4_000)
        let writer = StoreSplitSubscriptionSyncWriter(modelContainer: container)

        await writer.setSubscribed(
            feedURL: feedURL,
            isSubscribed: false,
            at: deletionDate
        )

        let context = ModelContext(container)
        let subscription = try XCTUnwrap(
            context.fetch(FetchDescriptor<SubscriptionSync>()).first
        )
        XCTAssertEqual(subscription.id, "https://example.com/feed.xml")
        XCTAssertFalse(subscription.isSubscribed)
        XCTAssertEqual(subscription.unsubscribedAt, deletionDate)
        XCTAssertEqual(subscription.updatedAt, deletionDate)
    }

    func testMergePolicyPrefersNewestIncomingRecord() {
        let existing = Date(timeIntervalSince1970: 1_000)
        let incoming = Date(timeIntervalSince1970: 2_000)

        XCTAssertTrue(StoreSplitMergePolicy.prefersIncoming(existingUpdatedAt: existing, incomingUpdatedAt: incoming))
        XCTAssertFalse(StoreSplitMergePolicy.prefersIncoming(existingUpdatedAt: incoming, incomingUpdatedAt: existing))
    }

    func testUpsertDecisionIsRepeatable() {
        let existing = Date(timeIntervalSince1970: 2_000)
        let olderIncoming = Date(timeIntervalSince1970: 1_000)
        let newerIncoming = Date(timeIntervalSince1970: 3_000)

        XCTAssertEqual(
            StoreSplitMergePolicy.upsertDecision(existingUpdatedAt: nil, incomingUpdatedAt: olderIncoming),
            .insert
        )
        XCTAssertEqual(
            StoreSplitMergePolicy.upsertDecision(existingUpdatedAt: existing, incomingUpdatedAt: olderIncoming),
            .keepExisting
        )
        XCTAssertEqual(
            StoreSplitMergePolicy.upsertDecision(existingUpdatedAt: existing, incomingUpdatedAt: newerIncoming),
            .replaceExisting
        )
        XCTAssertEqual(
            StoreSplitMergePolicy.upsertDecision(existingUpdatedAt: existing, incomingUpdatedAt: existing),
            .keepExisting
        )
    }

    func testPlaybackStateLookupPrefersSyncThenLegacyThenEmpty() {
        let synced = EpisodePlaybackStateValue(
            playPosition: 20,
            maxPlayPosition: 30,
            isPlayed: false,
            isArchived: false
        )
        let legacy = EpisodePlaybackStateValue(
            playPosition: 10,
            maxPlayPosition: 15,
            isPlayed: true,
            isArchived: true
        )

        XCTAssertEqual(EpisodePlaybackStateLookup.resolve(synced: synced, legacy: legacy), synced)
        XCTAssertEqual(EpisodePlaybackStateLookup.resolve(synced: nil, legacy: legacy), legacy)
        XCTAssertEqual(EpisodePlaybackStateLookup.resolve(synced: nil, legacy: nil), .empty)
    }

    @MainActor
    func testEpisodeStateWriterUpsertsNewestPlaybackState() async throws {
        let container = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let identity = EpisodeStableIdentity(
            feedURL: "https://example.com/feed.xml",
            episodeID: "guid:state"
        )
        let writer = StoreSplitEpisodeStateSyncWriter(modelContainer: container)
        await writer.upsert(
            StoreSplitEpisodeStateSnapshot(
                identity: identity,
                playPosition: 30,
                maxPlayPosition: 60,
                duration: 120,
                isPlayed: false,
                isArchived: false,
                wasSkipped: false,
                completedAt: nil,
                archivedAt: nil,
                firstPlayedAt: nil,
                lastPlayedAt: Date(timeIntervalSince1970: 1_000)
            ),
            at: Date(timeIntervalSince1970: 1_000)
        )
        await writer.upsert(
            StoreSplitEpisodeStateSnapshot(
                identity: identity,
                playPosition: 90,
                maxPlayPosition: 100,
                duration: 120,
                isPlayed: true,
                isArchived: false,
                wasSkipped: false,
                completedAt: Date(timeIntervalSince1970: 2_000),
                archivedAt: nil,
                firstPlayedAt: nil,
                lastPlayedAt: Date(timeIntervalSince1970: 2_000)
            ),
            at: Date(timeIntervalSince1970: 2_000)
        )

        let state = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<EpisodeStateSync>()).first
        )
        XCTAssertEqual(state.playPosition, 90)
        XCTAssertEqual(state.maxPlayPosition, 100)
        XCTAssertTrue(state.isPlayed)
    }

    func testQueueEntriesSortBySortIndex() {
        let entries = [
            QueueEntrySync(feedURL: "feed-a", episodeID: "episode-3", sortIndex: 3),
            QueueEntrySync(feedURL: "feed-a", episodeID: "episode-1", sortIndex: 1),
            QueueEntrySync(feedURL: "feed-a", episodeID: "episode-2", sortIndex: 2)
        ]

        XCTAssertEqual(entries.sorted { $0.sortIndex < $1.sortIndex }.map(\.episodeID), ["episode-1", "episode-2", "episode-3"])
    }

    func testQueueReorderingProducesContiguousIndexes() {
        let date = Date(timeIntervalSince1970: 1_000)
        let entries = [
            QueueEntryValue(id: "one", sortIndex: 0, updatedAt: date),
            QueueEntryValue(id: "two", sortIndex: 1, updatedAt: date),
            QueueEntryValue(id: "three", sortIndex: 2, updatedAt: date)
        ]

        let reordered = QueueEntryOrdering.reindexed(entries, movingID: "three", to: 0)

        XCTAssertEqual(reordered.map(\.id), ["three", "one", "two"])
        XCTAssertEqual(reordered.map(\.sortIndex), [0, 1, 2])
    }

    @MainActor
    func testPlaylistRemovalWritesPlaylistAndQueueTombstones() async throws {
        let container = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let identity = EpisodeStableIdentity(
            feedURL: "https://example.com/feed.xml",
            episodeID: "guid:episode-one"
        )
        let removal = StoreSplitPlaylistRemoval(
            playlistID: "playlist-one",
            isDefaultQueue: true,
            identity: identity
        )

        let writer = StoreSplitPlaylistSyncWriter(modelContainer: container)
        await writer.tombstone(
            [removal],
            at: Date(timeIntervalSince1970: 2_000)
        )

        let context = ModelContext(container)
        let playlistEntries = try context.fetch(FetchDescriptor<PlaylistEntrySync>())
        let queueEntries = try context.fetch(FetchDescriptor<QueueEntrySync>())

        XCTAssertEqual(playlistEntries.count, 1)
        XCTAssertEqual(playlistEntries[0].deletedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(queueEntries.count, 1)
        XCTAssertEqual(queueEntries[0].deletedAt, Date(timeIntervalSince1970: 2_000))
    }

    @MainActor
    func testPlaylistSnapshotUpsertsEntriesWithoutDeletingUnknownCloudEntries() async throws {
        let container = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let playlistID = UUID().uuidString
        let localIdentity = EpisodeStableIdentity(
            feedURL: "https://example.com/local.xml",
            episodeID: "guid:local"
        )
        let remoteIdentity = EpisodeStableIdentity(
            feedURL: "https://example.com/remote.xml",
            episodeID: "guid:remote"
        )
        container.mainContext.insert(
            PlaylistEntrySync(
                playlistID: playlistID,
                feedURL: remoteIdentity.feedURL,
                episodeID: remoteIdentity.episodeID,
                sortIndex: 4
            )
        )
        try container.mainContext.save()

        await StoreSplitPlaylistSyncWriter(modelContainer: container).upsert(
            StoreSplitPlaylistSnapshot(
                id: playlistID,
                title: Playlist.defaultQueueTitle,
                symbolName: Playlist.defaultQueueSymbolName,
                sortIndex: 0,
                kindRawValue: Playlist.Kind.manual.rawValue,
                smartFilterRawValue: nil,
                isHidden: false,
                entries: [
                    StoreSplitPlaylistEntrySnapshot(
                        identity: localIdentity,
                        sortIndex: 0,
                        addedAt: Date(timeIntervalSince1970: 2_000)
                    )
                ]
            )
        )

        let context = ModelContext(container)
        let playlistEntries = try context.fetch(FetchDescriptor<PlaylistEntrySync>())
        XCTAssertEqual(playlistEntries.count, 2)
        XCTAssertFalse(
            try XCTUnwrap(playlistEntries.first {
                $0.episodeID == remoteIdentity.episodeID
            }).isDeleted
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<QueueEntrySync>()),
            1
        )
    }

    func testBookmarkIdentitySurvivesMutableFields() {
        let id = UUID().uuidString
        let original = BookmarkSync(
            id: id,
            feedURL: "feed-a",
            episodeID: "episode-a",
            time: 10,
            title: "Original"
        )
        let edited = BookmarkSync(
            id: id,
            feedURL: "feed-a",
            episodeID: "episode-a",
            time: 12,
            title: "Edited"
        )

        XCTAssertEqual(original.id, edited.id)
    }

    @MainActor
    func testUserStateContainerAcceptsSyncModels() throws {
        let container = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let context = container.mainContext
        context.insert(SubscriptionSync(feedURL: "https://example.com/feed.xml"))
        context.insert(
            EpisodeStateSync(
                feedURL: "https://example.com/feed.xml",
                episodeID: "guid:episode-one",
                playPosition: 42
            )
        )
        try context.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SubscriptionSync>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EpisodeStateSync>()), 1)
    }

    @MainActor
    func testCacheContainerAcceptsMigrationAndExtensionModels() throws {
        let container = try ModelContainerManager.makeCacheContainer(
            isStoredInMemoryOnly: true
        )
        let context = container.mainContext
        context.insert(
            StoreSplitMigrationCheckpoint(
                id: "legacy-subscriptions",
                migrationVersion: 1,
                phase: "subscriptions"
            )
        )
        context.insert(
            CachedFeedExtensionElement(
                feedURL: "https://example.com/feed.xml",
                scope: "feed",
                namespaceURI: "https://podcastindex.org/namespace/1.0",
                qualifiedName: "podcast:funding",
                localName: "funding",
                payload: Data("<podcast:funding/>".utf8),
                ordinal: 0,
                contentHash: "hash"
            )
        )
        try context.save()

        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<StoreSplitMigrationCheckpoint>()),
            1
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<CachedFeedExtensionElement>()),
            1
        )
    }

#if DEBUG
    func testDevelopmentStoreResetRemovesSQLiteSidecars() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("SharedDatabase.sqlite")
        let artifactURLs = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm")
        ]
        for url in artifactURLs {
            try Data("test".utf8).write(to: url)
        }

        try ModelContainerManager.removeSQLiteArtifacts(for: storeURL)

        for url in artifactURLs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @MainActor
    func testDevelopmentResetDeletesSplitDataButPreservesLegacyStore() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let cacheContainer = try ModelContainerManager.makeCacheContainer(
            isStoredInMemoryOnly: true
        )
        legacyContainer.mainContext.insert(
            Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        )
        userStateContainer.mainContext.insert(
            SubscriptionSync(feedURL: "https://example.com/feed.xml")
        )
        userStateContainer.mainContext.insert(
            EpisodeStateSync(
                feedURL: "https://example.com/feed.xml",
                episodeID: "guid:episode"
            )
        )
        cacheContainer.mainContext.insert(
            StoreSplitMigrationCheckpoint(
                id: "migration",
                migrationVersion: 3,
                phase: "subscriptions"
            )
        )
        cacheContainer.mainContext.insert(
            AppliedAIContentRevision(episodeIdentityKey: "episode")
        )
        try legacyContainer.mainContext.save()
        try userStateContainer.mainContext.save()
        try cacheContainer.mainContext.save()

        let result = try await StoreSplitDevelopmentResetService.reset(
            userStateContainer: userStateContainer,
            cacheContainer: cacheContainer
        )

        XCTAssertEqual(result.userStateRecordsDeleted, 2)
        XCTAssertEqual(result.cacheRecordsDeleted, 2)
        let legacyVerification = ModelContext(legacyContainer)
        let userStateVerification = ModelContext(userStateContainer)
        let cacheVerification = ModelContext(cacheContainer)
        XCTAssertEqual(
            try legacyVerification.fetchCount(FetchDescriptor<Podcast>()),
            1
        )
        XCTAssertEqual(
            try userStateVerification.fetchCount(FetchDescriptor<SubscriptionSync>()),
            0
        )
        XCTAssertEqual(
            try userStateVerification.fetchCount(FetchDescriptor<EpisodeStateSync>()),
            0
        )
        XCTAssertEqual(
            try cacheVerification.fetchCount(
                FetchDescriptor<StoreSplitMigrationCheckpoint>()
            ),
            0
        )
        XCTAssertEqual(
            try cacheVerification.fetchCount(
                FetchDescriptor<AppliedAIContentRevision>()
            ),
            0
        )
    }

    @MainActor
    func testDevelopmentRepublishRecreatesLegacyPlaylistState() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let episode = Episode(
            guid: "republish",
            title: "Republish",
            url: URL(string: "https://example.com/republish.mp3")!,
            podcast: podcast
        )
        podcast.episodes = [episode]
        let playlist = Playlist()
        playlist.id = UUID()
        playlist.title = "Phone Playlist"
        playlist.deleteable = true
        let entry = PlaylistEntry(episode: episode, order: 0)
        entry.playlist = playlist
        playlist.items = [entry]
        legacyContainer.mainContext.insert(podcast)
        legacyContainer.mainContext.insert(playlist)
        try legacyContainer.mainContext.save()

        let result = await StoreSplitDevelopmentRepublishService.republish(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            scope: .playlists
        )

        XCTAssertEqual(result.playlists, 1)
        let context = ModelContext(userStateContainer)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<PlaylistSync>()),
            1
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<PlaylistEntrySync>()),
            1
        )
    }

    @MainActor
    func testDevelopmentRepublishDeduplicatesPlaylistEntries() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let episode = Episode(
            guid: "duplicate",
            title: "Duplicate",
            url: URL(string: "https://example.com/duplicate.mp3")!,
            podcast: podcast
        )
        podcast.episodes = [episode]
        let playlist = Playlist()
        let first = PlaylistEntry(episode: episode, order: 0)
        let duplicate = PlaylistEntry(episode: episode, order: 1)
        first.playlist = playlist
        duplicate.playlist = playlist
        playlist.items = [first, duplicate]
        legacyContainer.mainContext.insert(podcast)
        legacyContainer.mainContext.insert(playlist)
        try legacyContainer.mainContext.save()

        for _ in 0..<2 {
            _ = await StoreSplitDevelopmentRepublishService.republish(
                legacyContainer: legacyContainer,
                userStateContainer: userStateContainer,
                scope: .playlists
            )
        }

        let context = ModelContext(userStateContainer)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<PlaylistEntrySync>()),
            1
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<QueueEntrySync>()),
            1
        )
        let legacyContext = ModelContext(legacyContainer)
        let repairedPlaylist = try XCTUnwrap(
            try legacyContext.fetch(FetchDescriptor<Playlist>()).first
        )
        XCTAssertEqual(repairedPlaylist.ordered.count, 1)
        XCTAssertEqual(repairedPlaylist.ordered.first?.order, 0)
    }

    @MainActor
    func testDevelopmentRepublishPagesLargeEpisodeAndHistorySets() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        legacyContainer.mainContext.insert(podcast)

        for index in 0..<205 {
            let episode = Episode(
                guid: "episode-\(index)",
                title: "Episode \(index)",
                url: URL(string: "https://example.com/\(index).mp3")!,
                podcast: podcast
            )
            let metadata = EpisodeMetaData()
            metadata.episode = episode
            metadata.playPosition = Double(index + 1)
            episode.metaData = metadata
            let start = Date(timeIntervalSince1970: Double(index * 300))
            let session = PlaySession(
                id: UUID(),
                episode: episode,
                startTime: start,
                endTime: start.addingTimeInterval(120),
                startPosition: 0,
                endPosition: 120,
                endedCleanly: true
            )
            legacyContainer.mainContext.insert(episode)
            legacyContainer.mainContext.insert(metadata)
            legacyContainer.mainContext.insert(session)
        }
        try legacyContainer.mainContext.save()

        let stateResult = await StoreSplitDevelopmentRepublishService.republish(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            scope: .episodeStates
        )
        let historyResult = await StoreSplitDevelopmentRepublishService.republish(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            scope: .listeningHistory
        )

        XCTAssertEqual(stateResult.episodeStates, 205)
        XCTAssertEqual(historyResult.listeningSessions, 205)
        XCTAssertEqual(historyResult.storedCounts.episodeStates, 205)
        XCTAssertEqual(historyResult.storedCounts.listeningSessions, 205)
    }
#endif

    @MainActor
    func testMigrationStatusReportsPartialProgressAndFailures() throws {
        let container = try ModelContainerManager.makeCacheContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let context = container.mainContext
        context.insert(
            StoreSplitMigrationCheckpoint(
                id: "v\(StoreSplitMigrationService.migrationVersion).subscriptions",
                migrationVersion: StoreSplitMigrationService.migrationVersion,
                phase: "subscriptions",
                completedAt: Date(timeIntervalSince1970: 1_000),
                scannedCount: 12
            )
        )
        context.insert(
            StoreSplitMigrationCheckpoint(
                id: "v\(StoreSplitMigrationService.migrationVersion).episode_states",
                migrationVersion: StoreSplitMigrationService.migrationVersion,
                phase: "episode_states",
                cursor: "250",
                scannedCount: 250,
                failedCount: 1,
                lastError: "Test failure"
            )
        )
        try context.save()

        let status = StoreSplitMigrationDiagnostics.migrationStatus(
            cacheContext: context,
            userStateContext: userStateContainer.mainContext,
            isRunning: true
        )

        XCTAssertTrue(status.isRunning)
        XCTAssertFalse(status.isComplete)
        XCTAssertEqual(status.completedPhaseCount, 1)
        XCTAssertEqual(status.totalPhaseCount, 10)
        XCTAssertEqual(status.scannedItemCount, 262)
        XCTAssertEqual(status.failedItemCount, 1)
        XCTAssertEqual(status.phases.first { $0.id == "episode_states" }?.isComplete, false)
    }

    @MainActor
    func testMigrationStatusRequiresEveryCurrentPhaseToComplete() throws {
        let container = try ModelContainerManager.makeCacheContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let context = container.mainContext
        let phases = [
            "subscriptions",
            "episode_states",
            "playlists",
            "playlist_entries",
            "queue_entries",
            "bookmarks",
            "listening_history",
            "listening_summaries",
            "ai_transcripts",
            "ai_chapters"
        ]

        for phase in phases {
            context.insert(
                StoreSplitMigrationCheckpoint(
                    id: "v\(StoreSplitMigrationService.migrationVersion).\(phase)",
                    migrationVersion: StoreSplitMigrationService.migrationVersion,
                    phase: phase,
                    completedAt: Date(timeIntervalSince1970: 1_000),
                    scannedCount: 1
                )
            )
        }
        try context.save()

        let status = StoreSplitMigrationDiagnostics.migrationStatus(
            cacheContext: context,
            userStateContext: userStateContainer.mainContext,
            isRunning: false
        )

        XCTAssertTrue(status.isComplete)
        XCTAssertEqual(status.fractionCompleted, 1)
        XCTAssertEqual(status.scannedItemCount, phases.count)
    }

    @MainActor
    func testStoreSplitMigrationIsIdempotent() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let cacheContainer = try ModelContainerManager.makeCacheContainer(
            isStoredInMemoryOnly: true
        )
        let legacyContext = legacyContainer.mainContext
        let feedURL = URL(string: "https://example.com/feed.xml")!
        let episodeURL = URL(string: "https://cdn.example.com/episode.mp3")!
        let stateDate = Date(timeIntervalSince1970: 2_000)

        let podcast = Podcast(feed: feedURL)
        podcast.title = "Example"
        podcast.metaData?.subscriptionDate = Date(timeIntervalSince1970: 1_000)
        let episode = Episode(
            guid: "episode-one",
            title: "Episode One",
            publishDate: Date(timeIntervalSince1970: 500),
            url: episodeURL,
            podcast: podcast,
            duration: 120
        )
        episode.metaData?.playPosition = 42
        episode.metaData?.maxPlayposition = 60
        episode.metaData?.lastPlayed = stateDate
        podcast.episodes = [episode]

        let playlist = Playlist()
        let entry = PlaylistEntry(episode: episode, order: 0)
        entry.dateAdded = stateDate
        entry.playlist = playlist
        playlist.items = [entry]

        let bookmark = Bookmark(
            start: 30,
            title: "Remember this",
            type: .bookmark
        )
        bookmark.uuid = nil
        bookmark.creationtime = stateDate
        bookmark.bookmarkEpisode = episode
        episode.bookmarks = [bookmark]

        let session = PlaySession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
            episode: episode,
            deviceModel: "Test iPhone",
            osVersion: "26.0",
            appVersion: "1",
            startTime: Date(timeIntervalSince1970: 3_000),
            endTime: Date(timeIntervalSince1970: 3_120),
            startPosition: 0,
            endPosition: 120,
            silenceGapTimeSavedSeconds: 5,
            endedCleanly: true
        )
        episode.playSessions = [session]

        let summary = PlaySessionSummary(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222"),
            periodKind: PlaySessionSummaryPeriod.week.rawValue,
            periodStart: Date(timeIntervalSince1970: 0),
            podcastFeed: feedURL,
            podcastName: "Example",
            totalSeconds: 120,
            silenceGapTimeSavedSeconds: 5,
            playbackRateTimeSavedSeconds: 0,
            activeHourCount: 1
        )

        legacyContext.insert(podcast)
        legacyContext.insert(playlist)
        legacyContext.insert(summary)
        try legacyContext.save()

        _ = await StoreSplitMigrationService.migrate(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            cacheContainer: cacheContainer
        )
        let repeatedResult = await StoreSplitMigrationService.migrate(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            cacheContainer: cacheContainer
        )

        let destination = userStateContainer.mainContext
        XCTAssertEqual(try destination.fetchCount(FetchDescriptor<SubscriptionSync>()), 1)
        XCTAssertEqual(try destination.fetchCount(FetchDescriptor<EpisodeStateSync>()), 1)
        XCTAssertEqual(try destination.fetchCount(FetchDescriptor<PlaylistSync>()), 1)
        XCTAssertEqual(try destination.fetchCount(FetchDescriptor<PlaylistEntrySync>()), 1)
        XCTAssertEqual(try destination.fetchCount(FetchDescriptor<QueueEntrySync>()), 1)
        XCTAssertEqual(try destination.fetchCount(FetchDescriptor<BookmarkSync>()), 1)
        XCTAssertEqual(try destination.fetchCount(FetchDescriptor<ListeningHistorySync>()), 1)
        XCTAssertEqual(try destination.fetchCount(FetchDescriptor<ListeningSummarySync>()), 1)
        XCTAssertEqual(repeatedResult.listeningSummaries.updated, 0)
        XCTAssertEqual(repeatedResult.listeningSummaries.skipped, 1)
        XCTAssertNil(bookmark.uuid)

        let migratedBookmark = try XCTUnwrap(
            destination.fetch(FetchDescriptor<BookmarkSync>()).first
        )
        XCTAssertEqual(
            migratedBookmark.id,
            StableIdentityKey.make(
                "legacy-bookmark",
                episode.stableEpisodeIdentity.key,
                String(bookmark.start ?? 0),
                bookmark.title,
                String((bookmark.creationtime ?? .distantPast).timeIntervalSince1970)
            )
        )
    }

    @MainActor
    func testMigrationDoesNotOverwriteNewerSyncedSubscriptionTombstone() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let cacheContainer = try ModelContainerManager.makeCacheContainer(
            isStoredInMemoryOnly: true
        )
        let feedURL = URL(string: "https://example.com/feed.xml")!
        let normalizedFeedURL = PodcastFeedIdentity.normalizedFeedURLString(feedURL)

        let podcast = Podcast(feed: feedURL)
        podcast.metaData?.isSubscribed = true
        podcast.metaData?.subscriptionDate = Date(timeIntervalSince1970: 1_000)
        legacyContainer.mainContext.insert(podcast)
        try legacyContainer.mainContext.save()

        let tombstoneDate = Date(timeIntervalSince1970: 3_000)
        userStateContainer.mainContext.insert(
            SubscriptionSync(
                feedURL: normalizedFeedURL,
                isSubscribed: false,
                subscribedAt: Date(timeIntervalSince1970: 500),
                unsubscribedAt: tombstoneDate,
                updatedAt: tombstoneDate
            )
        )
        try userStateContainer.mainContext.save()

        _ = await StoreSplitMigrationService.migrate(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            cacheContainer: cacheContainer
        )

        let records = try userStateContainer.mainContext.fetch(
            FetchDescriptor<SubscriptionSync>()
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(records[0].isSubscribed)
        XCTAssertEqual(records[0].updatedAt, tombstoneDate)
    }

    func testListeningDeviceIdentityPersistsForInstallation() {
        let suiteName = "ListeningDeviceIdentityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let first = ListeningDeviceIdentity.current(defaults: defaults)
        let second = ListeningDeviceIdentity.current(defaults: defaults)

        XCTAssertEqual(first.id, second.id)
        XCTAssertFalse(first.id.isEmpty)
    }

    func testAITranscriptCodecChunksAndRoundTrips() throws {
        let lines = (0..<20).map { index in
            let text = Array(repeating: "Line \(index)", count: 8).joined(separator: " ")
            return AITranscriptLineValue(
                speaker: index.isMultiple(of: 2) ? "Host" : nil,
                text: text,
                startTime: Double(index * 10),
                endTime: Double(index * 10 + 9)
            )
        }

        let encoded = try AIContentSyncCodec.encodeTranscript(
            lines,
            maximumChunkBytes: 400
        )

        XCTAssertGreaterThan(encoded.chunks.count, 1)
        XCTAssertTrue(encoded.chunks.allSatisfy { Data($0.utf8).count <= 600 })
        XCTAssertEqual(
            try AIContentSyncCodec.decodeTranscript(
                chunks: encoded.chunks,
                expectedLineCount: lines.count,
                expectedContentHash: encoded.contentHash
            ),
            lines
        )
    }

    func testAITranscriptCodecRejectsIncompleteRevision() throws {
        let lines = (0..<10).map {
            AITranscriptLineValue(
                speaker: nil,
                text: String(repeating: "Transcript \($0) ", count: 10),
                startTime: Double($0),
                endTime: nil
            )
        }
        let encoded = try AIContentSyncCodec.encodeTranscript(
            lines,
            maximumChunkBytes: 300
        )

        XCTAssertThrowsError(
            try AIContentSyncCodec.decodeTranscript(
                chunks: Array(encoded.chunks.dropLast()),
                expectedLineCount: lines.count,
                expectedContentHash: encoded.contentHash
            )
        )
    }

    @MainActor
    func testAIContentImporterAppliesCompleteTranscriptAndOnlyReplacesAIChapters() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let cacheContainer = try ModelContainerManager.makeCacheContainer(
            isStoredInMemoryOnly: true
        )
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let episode = Episode(
            guid: "episode-ai",
            title: "AI Episode",
            url: URL(string: "https://example.com/episode.mp3")!,
            podcast: podcast
        )
        let podloveChapter = Marker(start: 0, title: "Publisher intro", type: .podlove)
        podloveChapter.episode = episode
        let oldAIChapter = Marker(start: 30, title: "Old AI", type: .ai)
        oldAIChapter.episode = episode
        episode.chapters = [podloveChapter, oldAIChapter]
        podcast.episodes = [episode]
        legacyContainer.mainContext.insert(podcast)
        try legacyContainer.mainContext.save()

        let transcriptLines = [
            AITranscriptLineValue(
                speaker: "Host",
                text: "Welcome",
                startTime: 0,
                endTime: 5
            ),
            AITranscriptLineValue(
                speaker: nil,
                text: "Main topic",
                startTime: 5,
                endTime: 20
            )
        ]
        let encodedTranscript = try AIContentSyncCodec.encodeTranscript(transcriptLines)
        let identity = episode.stableEpisodeIdentity
        userStateContainer.mainContext.insert(
            AITranscriptSync(
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                revisionID: encodedTranscript.revisionID,
                localeIdentifier: "en",
                chunkCount: encodedTranscript.chunks.count,
                lineCount: encodedTranscript.lineCount,
                contentHash: encodedTranscript.contentHash,
                generatedAt: Date(timeIntervalSince1970: 2_000)
            )
        )
        for (index, payload) in encodedTranscript.chunks.enumerated() {
            userStateContainer.mainContext.insert(
                AITranscriptChunkSync(
                    transcriptID: identity.key,
                    revisionID: encodedTranscript.revisionID,
                    chunkIndex: index,
                    payloadJSON: payload,
                    contentHash: AIContentSyncCodec.sha256Hex(Data(payload.utf8))
                )
            )
        }
        let chapterValues = [
            AIChapterValue(title: "New AI chapter", startTime: 45, duration: 30)
        ]
        let encodedChapters = try AIContentSyncCodec.encodeChapters(chapterValues)
        userStateContainer.mainContext.insert(
            AIChapterSetSync(
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                revisionID: encodedChapters.hash,
                payloadJSON: encodedChapters.payload,
                chapterCount: chapterValues.count,
                contentHash: encodedChapters.hash,
                generatedAt: Date(timeIntervalSince1970: 2_000)
            )
        )
        try userStateContainer.mainContext.save()

        let result = await StoreSplitAIContentImporter.apply(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            cacheContainer: cacheContainer
        )

        XCTAssertEqual(result.transcriptsApplied, 1)
        XCTAssertEqual(result.chaptersApplied, 1)
        let refreshedEpisode = try XCTUnwrap(
            legacyContainer.mainContext.fetch(FetchDescriptor<Episode>()).first
        )
        XCTAssertEqual(
            refreshedEpisode.transcriptLines?
                .sorted { $0.startTime < $1.startTime }
                .map(\.text),
            ["Welcome", "Main topic"]
        )
        XCTAssertTrue(refreshedEpisode.transcriptLines?.allSatisfy {
            $0.episode?.persistentModelID == refreshedEpisode.persistentModelID
        } == true)
        XCTAssertTrue(refreshedEpisode.chapters?.contains(where: {
            $0.type == .podlove && $0.title == "Publisher intro"
        }) == true)
        XCTAssertTrue(refreshedEpisode.chapters?.contains(where: {
            $0.type == .ai && $0.title == "New AI chapter"
        }) == true)
        XCTAssertFalse(refreshedEpisode.chapters?.contains(where: {
            $0.type == .ai && $0.title == "Old AI"
        }) == true)
    }

    @MainActor
    func testAIContentImporterAppliesLargeTranscriptWithRelationshipInverse() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let cacheContainer = try ModelContainerManager.makeCacheContainer(
            isStoredInMemoryOnly: true
        )
        let podcast = Podcast(feed: URL(string: "https://example.com/large-feed.xml")!)
        let episode = Episode(
            guid: "large-ai-transcript",
            title: "Large AI Transcript",
            url: URL(string: "https://example.com/large-episode.mp3")!,
            podcast: podcast
        )
        podcast.episodes = [episode]
        legacyContainer.mainContext.insert(podcast)
        try legacyContainer.mainContext.save()

        let lineCount = 3_200
        let transcriptLines = (0 ..< lineCount).map {
            AITranscriptLineValue(
                speaker: $0.isMultiple(of: 2) ? "Host" : nil,
                text: "Transcript line \($0)",
                startTime: Double($0),
                endTime: Double($0 + 1)
            )
        }
        let encodedTranscript = try AIContentSyncCodec.encodeTranscript(transcriptLines)
        let identity = episode.stableEpisodeIdentity
        userStateContainer.mainContext.insert(
            AITranscriptSync(
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                revisionID: encodedTranscript.revisionID,
                localeIdentifier: "en",
                chunkCount: encodedTranscript.chunks.count,
                lineCount: encodedTranscript.lineCount,
                contentHash: encodedTranscript.contentHash,
                generatedAt: Date(timeIntervalSince1970: 2_000)
            )
        )
        for (index, payload) in encodedTranscript.chunks.enumerated() {
            userStateContainer.mainContext.insert(
                AITranscriptChunkSync(
                    transcriptID: identity.key,
                    revisionID: encodedTranscript.revisionID,
                    chunkIndex: index,
                    payloadJSON: payload,
                    contentHash: AIContentSyncCodec.sha256Hex(Data(payload.utf8))
                )
            )
        }
        try userStateContainer.mainContext.save()

        let result = await StoreSplitAIContentImporter.apply(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            cacheContainer: cacheContainer
        )

        XCTAssertEqual(result.transcriptsApplied, 1)
        let refreshedEpisode = try XCTUnwrap(
            legacyContainer.mainContext.fetch(FetchDescriptor<Episode>()).first
        )
        let importedLines = try XCTUnwrap(refreshedEpisode.transcriptLines)
        XCTAssertEqual(importedLines.count, lineCount)
        XCTAssertTrue(importedLines.allSatisfy {
            $0.episode?.persistentModelID == refreshedEpisode.persistentModelID
        })
    }

    @MainActor
    func testAIContentImporterPreservesPublisherTranscript() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let cacheContainer = try ModelContainerManager.makeCacheContainer(
            isStoredInMemoryOnly: true
        )
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let episode = Episode(
            guid: "publisher-transcript",
            title: "Publisher Episode",
            url: URL(string: "https://example.com/publisher.mp3")!,
            podcast: podcast
        )
        episode.transcriptLines = [
            TranscriptLineAndTime(text: "Publisher supplied", startTime: 0)
        ]
        podcast.episodes = [episode]
        legacyContainer.mainContext.insert(podcast)
        try legacyContainer.mainContext.save()

        let values = [AITranscriptLineValue(
            speaker: nil,
            text: "Incoming AI",
            startTime: 0,
            endTime: nil
        )]
        let encoded = try AIContentSyncCodec.encodeTranscript(values)
        let identity = episode.stableEpisodeIdentity
        userStateContainer.mainContext.insert(
            AITranscriptSync(
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                revisionID: encoded.revisionID,
                chunkCount: encoded.chunks.count,
                lineCount: encoded.lineCount,
                contentHash: encoded.contentHash,
                generatedAt: .now
            )
        )
        for (index, payload) in encoded.chunks.enumerated() {
            userStateContainer.mainContext.insert(
                AITranscriptChunkSync(
                    transcriptID: identity.key,
                    revisionID: encoded.revisionID,
                    chunkIndex: index,
                    payloadJSON: payload,
                    contentHash: AIContentSyncCodec.sha256Hex(Data(payload.utf8))
                )
            )
        }
        try userStateContainer.mainContext.save()

        let result = await StoreSplitAIContentImporter.apply(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            cacheContainer: cacheContainer
        )

        XCTAssertEqual(result.transcriptsApplied, 0)
        let refreshedEpisode = try XCTUnwrap(
            legacyContainer.mainContext.fetch(FetchDescriptor<Episode>()).first
        )
        XCTAssertEqual(refreshedEpisode.transcriptLines?.first?.text, "Publisher supplied")
    }

    @MainActor
    func testAIContentImporterFindsEpisodeByEnclosureURLWithoutGUID() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let cacheContainer = try ModelContainerManager.makeCacheContainer(
            isStoredInMemoryOnly: true
        )
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let episode = Episode(
            title: "URL Identity Episode",
            url: URL(string: "https://example.com/url-identity.mp3")!,
            podcast: podcast
        )
        podcast.episodes = [episode]
        legacyContainer.mainContext.insert(podcast)
        try legacyContainer.mainContext.save()

        let values = [
            AITranscriptLineValue(
                speaker: nil,
                text: "Found without scanning the library",
                startTime: 0,
                endTime: 5
            )
        ]
        let encoded = try AIContentSyncCodec.encodeTranscript(values)
        let identity = episode.stableEpisodeIdentity
        userStateContainer.mainContext.insert(
            AITranscriptSync(
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                revisionID: encoded.revisionID,
                chunkCount: encoded.chunks.count,
                lineCount: encoded.lineCount,
                contentHash: encoded.contentHash,
                generatedAt: .now
            )
        )
        for (index, payload) in encoded.chunks.enumerated() {
            userStateContainer.mainContext.insert(
                AITranscriptChunkSync(
                    transcriptID: identity.key,
                    revisionID: encoded.revisionID,
                    chunkIndex: index,
                    payloadJSON: payload,
                    contentHash: AIContentSyncCodec.sha256Hex(Data(payload.utf8))
                )
            )
        }
        try userStateContainer.mainContext.save()

        let result = await StoreSplitAIContentImporter.apply(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            cacheContainer: cacheContainer
        )

        XCTAssertEqual(result.transcriptsApplied, 1)
        let refreshedEpisode = try XCTUnwrap(
            legacyContainer.mainContext.fetch(FetchDescriptor<Episode>()).first
        )
        XCTAssertEqual(
            refreshedEpisode.transcriptLines?.first?.text,
            "Found without scanning the library"
        )
    }

    @MainActor
    func testAITranscriptTombstoneRemovesGeneratedTranscriptButPreservesPublisherTranscript() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let cacheContainer = try ModelContainerManager.makeCacheContainer(
            isStoredInMemoryOnly: true
        )
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let generatedURL = URL(string: "https://example.com/generated.mp3")!
        let generatedEpisode = Episode(
            guid: "generated-transcript",
            title: "Generated Transcript",
            url: generatedURL,
            podcast: podcast
        )
        generatedEpisode.transcriptLines = [
            TranscriptLineAndTime(text: "Generated locally", startTime: 0)
        ]
        let publisherEpisode = Episode(
            guid: "publisher-transcript-tombstone",
            title: "Publisher Transcript",
            url: URL(string: "https://example.com/publisher-tombstone.mp3")!,
            podcast: podcast
        )
        publisherEpisode.transcriptLines = [
            TranscriptLineAndTime(text: "Publisher supplied", startTime: 0)
        ]
        podcast.episodes = [generatedEpisode, publisherEpisode]
        legacyContainer.mainContext.insert(podcast)
        legacyContainer.mainContext.insert(
            TranscriptionRecord(
                episodeURL: generatedURL,
                episodeTitle: generatedEpisode.title,
                podcastTitle: "Example",
                localeIdentifier: "en",
                startedAt: Date(timeIntervalSince1970: 1_000),
                finishedAt: Date(timeIntervalSince1970: 2_000),
                audioDuration: 10
            )
        )

        let deletionDate = Date(timeIntervalSince1970: 3_000)
        for episode in [generatedEpisode, publisherEpisode] {
            let identity = episode.stableEpisodeIdentity
            userStateContainer.mainContext.insert(
                AITranscriptSync(
                    feedURL: identity.feedURL,
                    episodeID: identity.episodeID,
                    revisionID: StableIdentityKey.make(
                        "deleted",
                        String(deletionDate.timeIntervalSince1970)
                    ),
                    chunkCount: 0,
                    lineCount: 0,
                    contentHash: "",
                    generatedAt: .distantPast,
                    deletedAt: deletionDate,
                    updatedAt: deletionDate
                )
            )
        }
        try legacyContainer.mainContext.save()
        try userStateContainer.mainContext.save()

        let result = await StoreSplitAIContentImporter.apply(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            cacheContainer: cacheContainer
        )

        XCTAssertEqual(result.transcriptsApplied, 1)
        let episodes = try legacyContainer.mainContext.fetch(FetchDescriptor<Episode>())
        let refreshedGenerated = try XCTUnwrap(
            episodes.first { $0.guid == "generated-transcript" }
        )
        let refreshedPublisher = try XCTUnwrap(
            episodes.first { $0.guid == "publisher-transcript-tombstone" }
        )
        XCTAssertTrue(refreshedGenerated.transcriptLines?.isEmpty != false)
        XCTAssertEqual(
            refreshedPublisher.transcriptLines?.first?.text,
            "Publisher supplied"
        )
    }

    @MainActor
    func testNewStoreReadImporterAppliesSubscriptionsAndEpisodeState() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let existingFeed = URL(string: "https://example.com/existing.xml")!
        let incomingFeed = URL(string: "https://example.com/incoming.xml")!
        let podcast = Podcast(feed: existingFeed)
        let episode = Episode(
            guid: "new-store-read",
            title: "New Store Read",
            url: URL(string: "https://example.com/new-store-read.mp3")!,
            podcast: podcast
        )
        let metadata = EpisodeMetaData()
        metadata.episode = episode
        metadata.playPosition = 10
        metadata.maxPlayposition = 20
        metadata.isArchived = false
        metadata.status = .inbox
        episode.metaData = metadata
        podcast.episodes = [episode]
        legacyContainer.mainContext.insert(podcast)

        let identity = episode.stableEpisodeIdentity
        userStateContainer.mainContext.insert(
            SubscriptionSync(
                feedURL: PodcastFeedIdentity.normalizedFeedURLString(incomingFeed),
                titleOverride: "Incoming Podcast"
            )
        )
        userStateContainer.mainContext.insert(
            EpisodeStateSync(
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                playPosition: 120,
                maxPlayPosition: 180,
                isPlayed: false,
                isArchived: true,
                archivedAt: Date(timeIntervalSince1970: 2_000),
                lastPlayedAt: Date(timeIntervalSince1970: 1_900)
            )
        )
        try legacyContainer.mainContext.save()
        try userStateContainer.mainContext.save()

        let result = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer
        )

        XCTAssertEqual(result.subscriptionsApplied, 1)
        XCTAssertEqual(result.episodeStatesApplied, 1)
        XCTAssertEqual(result.feedsToBootstrap, [incomingFeed])

        let verificationContext = ModelContext(legacyContainer)
        let podcasts = try verificationContext.fetch(FetchDescriptor<Podcast>())
        let importedPodcast = try XCTUnwrap(
            podcasts.first {
                $0.feed.map(PodcastFeedIdentity.normalizedFeedURLString)
                    == PodcastFeedIdentity.normalizedFeedURLString(incomingFeed)
            }
        )
        XCTAssertEqual(importedPodcast.title, "Incoming Podcast")
        XCTAssertEqual(importedPodcast.metaData?.isSubscribed, true)

        let refreshedEpisode = try XCTUnwrap(
            try verificationContext.fetch(FetchDescriptor<Episode>())
                .first { $0.guid == "new-store-read" }
        )
        XCTAssertEqual(refreshedEpisode.metaData?.playPosition, 120)
        XCTAssertEqual(refreshedEpisode.metaData?.maxPlayposition, 180)
        XCTAssertEqual(refreshedEpisode.metaData?.isArchived, true)
        XCTAssertEqual(refreshedEpisode.metaData?.status, .archived)
    }

    @MainActor
    func testNewStoreReadImporterAppliesPlaylistBookmarkAndHidesEquivalentFeedDuplicate() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let primaryPodcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        primaryPodcast.metaData = PodcastMetaData()
        primaryPodcast.metaData?.lastRefresh = Date(timeIntervalSince1970: 2_000)
        let duplicatePodcast = Podcast(feed: URL(string: "http://www.example.com/feed.xml/")!)
        duplicatePodcast.metaData = PodcastMetaData()
        duplicatePodcast.metaData?.lastRefresh = Date(timeIntervalSince1970: 1_000)
        let episode = Episode(
            guid: "playlist-sync",
            title: "Playlist Sync",
            url: URL(string: "https://example.com/playlist-sync.mp3")!,
            podcast: primaryPodcast
        )
        primaryPodcast.episodes = [episode]
        legacyContainer.mainContext.insert(primaryPodcast)
        legacyContainer.mainContext.insert(duplicatePodcast)

        let playlistID = UUID()
        let identity = episode.stableEpisodeIdentity
        userStateContainer.mainContext.insert(
            PlaylistSync(
                id: playlistID.uuidString,
                title: "Across Devices",
                symbolName: "music.note.list",
                sortIndex: 2,
                kindRawValue: Playlist.Kind.manual.rawValue
            )
        )
        userStateContainer.mainContext.insert(
            PlaylistEntrySync(
                playlistID: playlistID.uuidString,
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                sortIndex: 0
            )
        )
        let bookmarkID = UUID()
        userStateContainer.mainContext.insert(
            BookmarkSync(
                id: bookmarkID.uuidString,
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                time: 42,
                title: "Important moment"
            )
        )
        try legacyContainer.mainContext.save()
        try userStateContainer.mainContext.save()

        let result = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer
        )

        XCTAssertEqual(result.playlistsApplied, 1)
        XCTAssertEqual(result.playlistEntriesApplied, 1)
        XCTAssertEqual(result.bookmarksApplied, 1)
        XCTAssertEqual(result.duplicatePodcastsHidden, 1)

        let context = ModelContext(legacyContainer)
        let playlist = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Playlist>())
                .first { $0.id == playlistID }
        )
        XCTAssertEqual(playlist.title, "Across Devices")
        XCTAssertEqual(playlist.ordered.first?.episode?.guid, "playlist-sync")
        let bookmark = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Bookmark>())
                .first { $0.uuid == bookmarkID }
        )
        XCTAssertEqual(bookmark.start, 42)
        XCTAssertEqual(bookmark.bookmarkEpisode?.guid, "playlist-sync")
        let duplicate = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Podcast>())
                .first { $0.feed?.scheme == "http" }
        )
        XCTAssertEqual(duplicate.metaData?.isSubscribed, false)
    }

    @MainActor
    func testAuthoritativePlaylistImportReplacesStaleSameNamedLocalEntries() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let staleEpisode = Episode(
            guid: "stale",
            title: "Stale",
            url: URL(string: "https://example.com/stale.mp3")!,
            podcast: podcast
        )
        let phoneEpisode = Episode(
            guid: "phone",
            title: "Phone",
            url: URL(string: "https://example.com/phone.mp3")!,
            podcast: podcast
        )
        podcast.episodes = [staleEpisode, phoneEpisode]
        let macPlaylist = Playlist()
        macPlaylist.id = UUID()
        macPlaylist.title = Playlist.defaultQueueTitle
        let staleEntry = PlaylistEntry(episode: staleEpisode, order: 0)
        staleEntry.playlist = macPlaylist
        macPlaylist.items = [staleEntry]
        legacyContainer.mainContext.insert(podcast)
        legacyContainer.mainContext.insert(macPlaylist)

        let oldMacCloudPlaylistID = UUID().uuidString
        userStateContainer.mainContext.insert(
            PlaylistSync(
                id: oldMacCloudPlaylistID,
                title: Playlist.defaultQueueTitle,
                symbolName: Playlist.defaultQueueSymbolName,
                sortIndex: 0,
                kindRawValue: Playlist.Kind.manual.rawValue,
                updatedAt: Date(timeIntervalSince1970: 1_000)
            )
        )
        let phoneCloudPlaylistID = UUID().uuidString
        userStateContainer.mainContext.insert(
            PlaylistSync(
                id: phoneCloudPlaylistID,
                title: Playlist.defaultQueueTitle,
                symbolName: Playlist.defaultQueueSymbolName,
                sortIndex: 0,
                kindRawValue: Playlist.Kind.manual.rawValue,
                updatedAt: Date(timeIntervalSince1970: 2_000)
            )
        )
        let phoneIdentity = phoneEpisode.stableEpisodeIdentity
        userStateContainer.mainContext.insert(
            PlaylistEntrySync(
                playlistID: phoneCloudPlaylistID,
                feedURL: phoneIdentity.feedURL,
                episodeID: phoneIdentity.episodeID,
                sortIndex: 0,
                updatedAt: Date(timeIntervalSince1970: 2_000)
            )
        )
        try legacyContainer.mainContext.save()
        try userStateContainer.mainContext.save()

        _ = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            authoritativePlaylists: true
        )

        let context = ModelContext(legacyContainer)
        let queue = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Playlist>())
                .first { $0.title == Playlist.defaultQueueTitle }
        )
        XCTAssertEqual(queue.id, macPlaylist.id)
        XCTAssertEqual(queue.ordered.map { $0.episode?.guid }, ["phone"])
    }

    @MainActor
    func testNewStoreReadImporterProjectsDeduplicatedListeningHistory() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let episode = Episode(
            guid: "history",
            title: "History",
            url: URL(string: "https://example.com/history.mp3")!,
            podcast: podcast
        )
        podcast.episodes = [episode]
        legacyContainer.mainContext.insert(podcast)

        let identity = episode.stableEpisodeIdentity
        for (id, device, updatedAt) in [
            ("phone-copy", "phone", Date(timeIntervalSince1970: 1_120)),
            ("mac-copy", "mac", Date(timeIntervalSince1970: 1_121))
        ] {
            userStateContainer.mainContext.insert(
                ListeningHistorySync(
                    id: id,
                    feedURL: identity.feedURL,
                    episodeID: identity.episodeID,
                    podcastName: "Example",
                    episodeTitle: episode.title,
                    sourceDeviceID: device,
                    startedAt: Date(timeIntervalSince1970: 1_000),
                    endedAt: Date(timeIntervalSince1970: 1_120),
                    startPosition: 10,
                    endPosition: 130,
                    listenedSeconds: 120,
                    endedCleanly: true,
                    updatedAt: updatedAt
                )
            )
        }
        try legacyContainer.mainContext.save()
        try userStateContainer.mainContext.save()

        _ = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer
        )
        _ = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer
        )

        let context = ModelContext(legacyContainer)
        let sessions = try context.fetch(FetchDescriptor<PlaySession>())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.episode?.guid, "history")
        XCTAssertEqual(sessions.first?.sourceDeviceID, "mac")
        XCTAssertEqual(sessions.first?.startTime, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(sessions.first?.endTime, Date(timeIntervalSince1970: 1_120))
    }

    @MainActor
    func testNewStoreReadImporterCanSkipLegacyListeningHistoryProjection() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let episode = Episode(
            guid: "history-skip",
            title: "History Skip",
            url: URL(string: "https://example.com/history-skip.mp3")!,
            podcast: podcast
        )
        podcast.episodes = [episode]
        legacyContainer.mainContext.insert(podcast)
        legacyContainer.mainContext.insert(
            PlaySession(
                id: UUID(),
                episode: episode,
                sourceDeviceID: "old-device",
                sourceDeviceName: "Old Device",
                appVersion: ListeningDeviceIdentity.splitStoreProjectionAppVersion,
                startTime: Date(timeIntervalSince1970: 900),
                endTime: Date(timeIntervalSince1970: 960),
                startPosition: 0,
                endPosition: 60,
                endedCleanly: true
            )
        )

        let identity = episode.stableEpisodeIdentity
        userStateContainer.mainContext.insert(
            ListeningHistorySync(
                id: "fresh-copy",
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                podcastName: "Example",
                episodeTitle: episode.title,
                sourceDeviceID: "phone",
                startedAt: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 1_120),
                startPosition: 10,
                endPosition: 130,
                listenedSeconds: 120,
                endedCleanly: true,
                updatedAt: Date(timeIntervalSince1970: 1_120)
            )
        )
        try legacyContainer.mainContext.save()
        try userStateContainer.mainContext.save()

        let result = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            projectListeningHistoryToLegacy: false
        )

        XCTAssertEqual(result.listeningHistoryApplied, 0)

        let context = ModelContext(legacyContainer)
        let sessions = try context.fetch(FetchDescriptor<PlaySession>())
        XCTAssertTrue(sessions.isEmpty)
    }

    @MainActor
    func testNewStoreReadImporterSkipsStaleEpisodeStatesWhenRecencyCutoffIsSet() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let staleEpisode = Episode(
            guid: "stale-state",
            title: "Stale State",
            url: URL(string: "https://example.com/stale-state.mp3")!,
            podcast: podcast
        )
        let recentEpisode = Episode(
            guid: "recent-state",
            title: "Recent State",
            url: URL(string: "https://example.com/recent-state.mp3")!,
            podcast: podcast
        )
        podcast.episodes = [staleEpisode, recentEpisode]
        staleEpisode.metaData = EpisodeMetaData()
        recentEpisode.metaData = EpisodeMetaData()
        legacyContainer.mainContext.insert(podcast)

        let staleIdentity = staleEpisode.stableEpisodeIdentity
        let recentIdentity = recentEpisode.stableEpisodeIdentity
        userStateContainer.mainContext.insert(
            EpisodeStateSync(
                feedURL: staleIdentity.feedURL,
                episodeID: staleIdentity.episodeID,
                playPosition: 0,
                maxPlayPosition: 0,
                isPlayed: true,
                completedAt: Date(timeIntervalSince1970: 100),
                lastPlayedAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )
        userStateContainer.mainContext.insert(
            EpisodeStateSync(
                feedURL: recentIdentity.feedURL,
                episodeID: recentIdentity.episodeID,
                playPosition: 25,
                maxPlayPosition: 50,
                lastPlayedAt: Date(timeIntervalSince1970: 10_000),
                updatedAt: Date(timeIntervalSince1970: 10_000)
            )
        )
        try legacyContainer.mainContext.save()
        try userStateContainer.mainContext.save()

        let cutoff = Date(timeIntervalSince1970: 5_000)
        let result = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            episodeStateProjectionRecencyCutoff: cutoff
        )

        XCTAssertEqual(result.episodeStatesApplied, 1)

        let context = ModelContext(legacyContainer)
        let stale = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Episode>())
                .first { $0.guid == "stale-state" }
        )
        let recent = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Episode>())
                .first { $0.guid == "recent-state" }
        )
        XCTAssertNil(stale.metaData?.lastPlayed)
        XCTAssertEqual(recent.metaData?.playPosition, 25)
    }

    @MainActor
    func testNewStoreReadImporterRemovesStaleProjectedListeningHistory() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        let staleEpisode = Episode(
            guid: "stale-history",
            title: "Stale History",
            url: URL(string: "https://example.com/stale-history.mp3")!,
            podcast: podcast
        )
        let currentEpisode = Episode(
            guid: "current-history",
            title: "Current History",
            url: URL(string: "https://example.com/current-history.mp3")!,
            podcast: podcast
        )
        podcast.episodes = [staleEpisode, currentEpisode]
        legacyContainer.mainContext.insert(podcast)

        let staleSession = PlaySession(
            id: UUID(),
            episode: staleEpisode,
            sourceDeviceID: "old-device",
            sourceDeviceName: "Old Device",
            appVersion: ListeningDeviceIdentity.splitStoreProjectionAppVersion,
            startTime: Date(timeIntervalSince1970: 900),
            endTime: Date(timeIntervalSince1970: 960),
            startPosition: 0,
            endPosition: 60,
            endedCleanly: true
        )
        legacyContainer.mainContext.insert(staleSession)

        let identity = currentEpisode.stableEpisodeIdentity
        userStateContainer.mainContext.insert(
            ListeningHistorySync(
                id: "fresh-copy",
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                podcastName: "Example",
                episodeTitle: currentEpisode.title,
                sourceDeviceID: "phone",
                startedAt: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 1_120),
                startPosition: 10,
                endPosition: 130,
                listenedSeconds: 120,
                endedCleanly: true,
                updatedAt: Date(timeIntervalSince1970: 1_120)
            )
        )
        try legacyContainer.mainContext.save()
        try userStateContainer.mainContext.save()

        _ = await StoreSplitUserStateImporter.apply(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer
        )

        let context = ModelContext(legacyContainer)
        let sessions = try context.fetch(FetchDescriptor<PlaySession>())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.episode?.guid, "current-history")
        XCTAssertEqual(
            sessions.first?.appVersion,
            ListeningDeviceIdentity.splitStoreProjectionAppVersion
        )
    }

    @MainActor
    func testMigrationBackfillsExistingAITranscriptAndChaptersIdempotently() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let userStateContainer = try ModelContainerManager.makeUserStateContainer(
            isStoredInMemoryOnly: true
        )
        let cacheContainer = try ModelContainerManager.makeCacheContainer(
            isStoredInMemoryOnly: true
        )
        let feedURL = URL(string: "https://example.com/feed.xml")!
        let episodeURL = URL(string: "https://example.com/migrated-ai.mp3")!
        let podcast = Podcast(feed: feedURL)
        let episode = Episode(
            guid: "migrated-ai",
            title: "Migrated AI",
            url: episodeURL,
            podcast: podcast
        )
        let line = TranscriptLineAndTime(
            speaker: "Host",
            text: "Generated locally",
            startTime: 0,
            endTime: 10
        )
        line.episode = episode
        episode.transcriptLines = [line]
        let aiChapter = Marker(start: 0, title: "Generated chapter", type: .ai)
        aiChapter.creationtime = Date(timeIntervalSince1970: 2_000)
        aiChapter.episode = episode
        episode.chapters = [aiChapter]
        podcast.episodes = [episode]
        legacyContainer.mainContext.insert(podcast)
        legacyContainer.mainContext.insert(
            TranscriptionRecord(
                episodeURL: episodeURL,
                episodeTitle: episode.title,
                podcastTitle: "Example",
                localeIdentifier: "en",
                startedAt: Date(timeIntervalSince1970: 1_900),
                finishedAt: Date(timeIntervalSince1970: 2_000),
                audioDuration: 10
            )
        )
        try legacyContainer.mainContext.save()

        _ = await StoreSplitMigrationService.migrate(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            cacheContainer: cacheContainer
        )
        let repeated = await StoreSplitMigrationService.migrate(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            cacheContainer: cacheContainer
        )

        XCTAssertEqual(
            try userStateContainer.mainContext.fetchCount(
                FetchDescriptor<AITranscriptSync>()
            ),
            1
        )
        XCTAssertEqual(
            try userStateContainer.mainContext.fetchCount(
                FetchDescriptor<AITranscriptChunkSync>()
            ),
            1
        )
        XCTAssertEqual(
            try userStateContainer.mainContext.fetchCount(
                FetchDescriptor<AIChapterSetSync>()
            ),
            1
        )
        XCTAssertEqual(repeated.aiTranscripts.updated, 0)
        XCTAssertEqual(repeated.aiChapters.updated, 0)
    }
}
