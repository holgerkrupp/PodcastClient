import SwiftData
import XCTest
@testable import UpNext

final class StableIdentityTests: XCTestCase {
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
