import SwiftData
import XCTest
@testable import UpNext

/// Every fact in the final runtime has to reach UserState or PodcastCache, because
/// the in-memory library graph is rebuilt from those two stores on each launch.
final class StoreSplitFinalRuntimeDurabilityTests: XCTestCase {
    private let feed = URL(string: "https://example.com/durability.xml")!
    private var directory: URL!
    private var cacheURL: URL { directory.appendingPathComponent("PodcastCache.sqlite") }
    private var stateURL: URL { directory.appendingPathComponent("UserState.sqlite") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Projects one podcast with one episode into the disk-backed cache, after
    /// `configure` has changed the in-memory source graph.
    @MainActor
    private func seedCache(
        configure: (Podcast, Episode, ModelContext) -> Void = { _, _, _ in }
    ) throws -> EpisodeStableIdentity {
        let source = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let cache = try ModelContainerManager.makeCacheContainer(storageURL: cacheURL)
        let podcast = Podcast(feed: feed)
        let episode = Episode(
            guid: "episode",
            title: "Episode",
            url: URL(string: "https://example.com/episode.mp3")!,
            podcast: podcast
        )
        podcast.episodes = [episode]
        source.mainContext.insert(podcast)
        source.mainContext.insert(episode)
        configure(podcast, episode, source.mainContext)
        try source.mainContext.save()
        XCTAssertTrue(StoreSplitFeedCacheWriter.upsertFeed(
            feedURL: feed,
            legacyContainer: source,
            cacheContainer: cache
        ))
        return episode.stableEpisodeIdentity
    }

    @MainActor
    private func relaunch() throws -> (runtime: ModelContainer, cache: ModelContainer) {
        let cache = try ModelContainerManager.makeCacheContainer(storageURL: cacheURL)
        let runtime = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        XCTAssertEqual(
            StoreSplitCompatibilityProjectionService.rebuild(
                cacheContainer: cache,
                runtimeContainer: runtime
            ).failed,
            0
        )
        return (runtime, cache)
    }

    @MainActor
    private func hydrate(_ runtime: ModelContainer, cache: ModelContainer) async throws {
        let state = try ModelContainerManager.makeUserStateContainer(storageURL: stateURL)
        let result = await StoreSplitUserStateImporter.apply(
            legacyContainer: runtime,
            userStateContainer: state,
            cacheContainer: cache,
            projectListeningHistoryToLegacy: false,
            isInitialRuntimeHydration: true
        )
        XCTAssertEqual(result.failed, 0)
    }

    // MARK: - Status

    @MainActor
    func testArchivedAndHistoryStatusRoundTrip() throws {
        _ = try seedCache { _, episode, _ in
            episode.metaData?.isInbox = false
            episode.metaData?.setArchived(true)
        }
        var (runtime, _) = try relaunch()
        var metadata = try XCTUnwrap(ModelContext(runtime).fetch(FetchDescriptor<Episode>()).first?.metaData)
        XCTAssertEqual(metadata.status, .archived)
        XCTAssertEqual(metadata.isArchived, true)

        _ = try seedCache { _, episode, _ in
            episode.metaData?.isInbox = false
            episode.metaData?.isHistory = true
            episode.metaData?.reconcileLegacyStatus()
        }
        (runtime, _) = try relaunch()
        metadata = try XCTUnwrap(ModelContext(runtime).fetch(FetchDescriptor<Episode>()).first?.metaData)
        XCTAssertEqual(metadata.status, .history)
        XCTAssertEqual(metadata.isHistory, true)
    }

    // MARK: - Deletion

    @MainActor
    func testDeletedEpisodeStaysDeletedAfterRebuild() throws {
        let identity = try seedCache { _, episode, context in
            let chapter = Marker(start: 1, title: "Chapter", type: .mp3)
            context.insert(chapter)
            chapter.episode = episode
        }
        let cache = try ModelContainerManager.makeCacheContainer(storageURL: cacheURL)
        XCTAssertEqual(try ModelContext(cache).fetchCount(FetchDescriptor<CachedChapter>()), 1)
        try StoreSplitFeedCacheWriter.deleteEpisode(identity: identity, cacheContainer: cache)

        let (runtime, reopened) = try relaunch()
        XCTAssertEqual(try ModelContext(runtime).fetchCount(FetchDescriptor<Episode>()), 0)
        XCTAssertEqual(try ModelContext(runtime).fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try ModelContext(reopened).fetchCount(FetchDescriptor<CachedChapter>()), 0)
        XCTAssertEqual(try ModelContext(reopened).fetchCount(FetchDescriptor<CachedDownloadRecord>()), 0)
    }

    @MainActor
    func testDeletedPodcastStaysDeletedAfterRebuild() throws {
        _ = try seedCache()
        let cache = try ModelContainerManager.makeCacheContainer(storageURL: cacheURL)
        try StoreSplitFeedCacheWriter.deletePodcast(feedURL: feed, cacheContainer: cache)

        let (runtime, reopened) = try relaunch()
        XCTAssertEqual(try ModelContext(runtime).fetchCount(FetchDescriptor<Podcast>()), 0)
        XCTAssertEqual(try ModelContext(reopened).fetchCount(FetchDescriptor<CachedEpisode>()), 0)
    }

    // MARK: - Subscription default

    @MainActor
    func testCachedPodcastIsSubscribedOnlyWhenUserStateSaysSo() async throws {
        _ = try seedCache()
        var (runtime, cache) = try relaunch()
        try await hydrate(runtime, cache: cache)
        XCTAssertEqual(
            try ModelContext(runtime).fetch(FetchDescriptor<Podcast>()).first?.metaData?.isSubscribed,
            false
        )

        do {
            let state = try ModelContainerManager.makeUserStateContainer(storageURL: stateURL)
            state.mainContext.insert(SubscriptionSync(
                feedURL: PodcastFeedIdentity.normalizedFeedURLString(feed),
                isSubscribed: true,
                subscribedAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2)
            ))
            try state.mainContext.save()
        }
        (runtime, cache) = try relaunch()
        try await hydrate(runtime, cache: cache)
        let metadata = try ModelContext(runtime).fetch(FetchDescriptor<Podcast>()).first?.metaData
        XCTAssertEqual(metadata?.isSubscribed, true)
        XCTAssertEqual(metadata?.subscriptionDate, Date(timeIntervalSince1970: 1))
    }

    // MARK: - Refresh metadata

    @MainActor
    func testRefreshMetadataRoundTripsAndSurvivesParsedProjection() throws {
        _ = try seedCache()
        let checkedAt = Date(timeIntervalSince1970: 1_000)
        let metadata = PodcastMetaData()
        metadata.lastRefresh = checkedAt
        metadata.feedUpdated = false
        metadata.feedUpdateCheckDate = checkedAt
        metadata.consecutiveFeedFailureCount = 2
        metadata.firstConsecutiveFeedFailureDate = checkedAt
        metadata.lastFeedFailureDate = checkedAt
        metadata.lastFeedFailureStatusCode = 500
        metadata.lastFeedFailureMessage = "Failed"
        metadata.authenticationRetryAfter = checkedAt
        metadata.nextPredictedReleaseDate = checkedAt
        let cache = try ModelContainerManager.makeCacheContainer(storageURL: cacheURL)
        StoreSplitFeedCacheWriter.updateRefreshMetadata(
            feedURL: feed,
            snapshot: .init(metadata),
            cacheContainer: cache
        )
        XCTAssertTrue(StoreSplitFeedCacheWriter.projectParsedFeed(
            feedURL: feed,
            parsedFeed: ["title": "Refreshed"],
            episodeRows: [],
            isCompleteFeed: true,
            cacheContainer: cache
        ).completed)

        let (runtime, _) = try relaunch()
        let restored = try XCTUnwrap(ModelContext(runtime).fetch(FetchDescriptor<Podcast>()).first?.metaData)
        XCTAssertEqual(restored.lastRefresh, checkedAt)
        XCTAssertEqual(restored.feedUpdated, false)
        XCTAssertEqual(restored.feedUpdateCheckDate, checkedAt)
        XCTAssertEqual(restored.consecutiveFeedFailureCount, 2)
        XCTAssertEqual(restored.firstConsecutiveFeedFailureDate, checkedAt)
        XCTAssertEqual(restored.lastFeedFailureDate, checkedAt)
        XCTAssertEqual(restored.lastFeedFailureStatusCode, 500)
        XCTAssertEqual(restored.lastFeedFailureMessage, "Failed")
        XCTAssertEqual(restored.authenticationRetryAfter, checkedAt)
        XCTAssertEqual(restored.nextPredictedReleaseDate, checkedAt)
    }

    // MARK: - Local settings

    @MainActor
    func testLocalSettingsRoundTripForPodcastAndGlobalScope() async throws {
        _ = try seedCache { podcast, _, context in
            let settings = PodcastSettings(podcast: podcast)
            context.insert(settings)
            podcast.settings = settings
            settings.enableAdvertisementDetection = true
            settings.transcriptionMaxSnippetDurationSeconds = 3
            settings.voices = ["en": ["name": "Voice"]]
            settings.sleepTimerVoice = "custom"

            let global = PodcastSettings(defaultSettings: true)
            context.insert(global)
            global.enableTranscriptions = false

            let cache = try! ModelContainerManager.makeCacheContainer(storageURL: cacheURL)
            let cacheContext = ModelContext(cache)
            cacheContext.insert(CachedPodcastLocalSettings(
                feedURL: PodcastFeedIdentity.normalizedFeedURLString(feed),
                payload: try! JSONEncoder().encode(PodcastLocalSettingsPayload(settings))
            ))
            cacheContext.insert(CachedPodcastLocalSettings(
                feedURL: nil,
                payload: try! JSONEncoder().encode(PodcastLocalSettingsPayload(global))
            ))
            try! cacheContext.save()
        }

        let (runtime, cache) = try relaunch()
        try await hydrate(runtime, cache: cache)
        let context = ModelContext(runtime)
        let settings = try XCTUnwrap(context.fetch(FetchDescriptor<Podcast>()).first?.settings)
        XCTAssertTrue(settings.enableAdvertisementDetection)
        XCTAssertEqual(settings.transcriptionMaxSnippetDurationSeconds, 3)
        XCTAssertEqual(settings.voices, ["en": ["name": "Voice"]])
        XCTAssertEqual(settings.sleepTimerVoice, "custom")

        let globalTitle = PodcastSettings.globalSettingsTitle
        let global = try XCTUnwrap(context.fetch(FetchDescriptor<PodcastSettings>(
            predicate: #Predicate { $0.title == globalTitle }
        )).first)
        XCTAssertFalse(global.enableTranscriptions)
    }

    // MARK: - Bookmark detail

    @MainActor
    func testBookmarkLocalFieldsRoundTrip() async throws {
        let bookmarkID = UUID().uuidString
        let link = URL(string: "https://example.com/link")!
        let imageData = Data([1, 2, 3])
        let identity = try seedCache { _, episode, context in
            let bookmark = Bookmark(start: 10, title: "Bookmark", type: .bookmark, imageData: imageData, duration: 5)
            context.insert(bookmark)
            bookmark.bookmarkEpisode = episode
            bookmark.link = link
            bookmark.progress = 0.5
            let episodeIdentity = episode.stableEpisodeIdentity

            let cache = try! ModelContainerManager.makeCacheContainer(storageURL: cacheURL)
            let cacheContext = ModelContext(cache)
            let detail = CachedBookmarkDetail(
                id: bookmarkID,
                feedURL: episodeIdentity.feedURL,
                episodeID: episodeIdentity.episodeID
            )
            detail.imageData = bookmark.imageData
            detail.duration = bookmark.duration
            detail.endTime = bookmark.endTime
            detail.link = bookmark.link
            detail.progress = bookmark.progress
            cacheContext.insert(detail)
            try! cacheContext.save()
        }
        do {
            let state = try ModelContainerManager.makeUserStateContainer(storageURL: stateURL)
            state.mainContext.insert(BookmarkSync(
                id: bookmarkID,
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                time: 10,
                title: "Bookmark",
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2),
                sourceDeviceID: "test"
            ))
            try state.mainContext.save()
        }

        let (runtime, cache) = try relaunch()
        try await hydrate(runtime, cache: cache)
        let bookmark = try XCTUnwrap(ModelContext(runtime).fetch(FetchDescriptor<Bookmark>()).first)
        XCTAssertEqual(bookmark.imageData, imageData)
        XCTAssertEqual(bookmark.duration, 5)
        XCTAssertEqual(bookmark.endTime, 15)
        XCTAssertEqual(bookmark.link, link)
        XCTAssertEqual(bookmark.progress, 0.5)
    }

    // MARK: - Analytics

    @MainActor
    func testEpisodeAnalyticsRoundTripAndSurviveParsedRefresh() throws {
        let startedAt = Date(timeIntervalSince1970: 500)
        _ = try seedCache { _, episode, _ in
            episode.metaData?.isInbox = false
            episode.metaData?.setArchived(true)
            episode.metaData?.playbackStartTimes = .init([startedAt])
            episode.metaData?.playbackDurations = .init([60])
            episode.metaData?.silenceGapTimeSavedDurations = .init([2])
            episode.metaData?.playbackSpeeds = .init([1.5])
            episode.metaData?.totalListenTime = 60
            episode.metaData?.totalSilenceGapTimeSaved = 2
        }
        // A GET refresh hands every parsed row to the projection, built from
        // drafts with default metadata. None of this may be reset by it.
        let cache = try ModelContainerManager.makeCacheContainer(storageURL: cacheURL)
        XCTAssertTrue(StoreSplitFeedCacheWriter.projectParsedFeed(
            feedURL: feed,
            parsedFeed: ["title": "Refreshed"],
            episodeRows: [[
                "guid": "episode",
                "title": "Episode",
                "enclosure": [["url": "https://example.com/episode.mp3", "type": "audio/mpeg"]]
            ]],
            isCompleteFeed: true,
            cacheContainer: cache
        ).completed)

        let (runtime, _) = try relaunch()
        let metadata = try XCTUnwrap(ModelContext(runtime).fetch(FetchDescriptor<Episode>()).first?.metaData)
        XCTAssertEqual(metadata.playbackStartTimes?.elements, [startedAt])
        XCTAssertEqual(metadata.playbackDurations?.elements, [60])
        XCTAssertEqual(metadata.silenceGapTimeSavedDurations?.elements, [2])
        XCTAssertEqual(metadata.playbackSpeeds?.elements, [1.5])
        XCTAssertEqual(metadata.totalListenTime, 60)
        XCTAssertEqual(metadata.totalSilenceGapTimeSaved, 2)
        XCTAssertEqual(metadata.status, .archived)
    }

    // MARK: - Transcription history

    @MainActor
    func testTranscriptionRecordsAreRestoredByRebuild() throws {
        let identity = try seedCache()
        let recordID = UUID()
        let cache = try ModelContainerManager.makeCacheContainer(storageURL: cacheURL)
        StoreSplitFeedCacheWriter.upsertTranscriptionRecord(
            .init(
                id: recordID,
                identity: identity,
                episodeURL: URL(string: "https://example.com/episode.mp3"),
                episodeTitle: "Episode",
                podcastTitle: nil,
                localeIdentifier: "en",
                startedAt: Date(timeIntervalSince1970: 1),
                finishedAt: Date(timeIntervalSince1970: 11),
                audioDuration: 100,
                transcriptionDuration: 10
            ),
            cacheContainer: cache
        )

        let (runtime, _) = try relaunch()
        let suiteName = "PodcastClient.transcriptionMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertTrue(StoreSplitCacheLocalDataMigration.migrateIfNeeded(
            cache: cache,
            library: runtime,
            defaults: defaults
        ))
        let record = try XCTUnwrap(ModelContext(runtime).fetch(FetchDescriptor<TranscriptionRecord>()).first)
        XCTAssertEqual(record.id, recordID)
        XCTAssertEqual(record.transcriptionDuration, 10)
    }

    @MainActor
    func testCachedAIStagingMigratesToLibraryAndPreservesChapterPlaybackState() throws {
        let cache = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        let library = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let podcast = Podcast(feed: feed)
        let episode = Episode(
            guid: "ai-fixture-guid",
            title: "Episode",
            url: URL(string: "https://example.com/ai-fixture.mp3")!,
            podcast: podcast
        )
        let episodeID = episode.stableEpisodeIdentity.episodeID
        podcast.episodes = [episode]
        library.mainContext.insert(podcast)
        library.mainContext.insert(episode)
        let legacyAIEpisode = Episode(
            guid: "legacy-ai-fixture-guid",
            title: "Legacy AI episode",
            url: URL(string: "https://example.com/legacy-ai-fixture.mp3")!,
            podcast: podcast
        )
        podcast.episodes?.append(legacyAIEpisode)
        library.mainContext.insert(legacyAIEpisode)
        try library.mainContext.save()

        let cacheContext = ModelContext(cache)
        let generatedAt = Date(timeIntervalSince1970: 20)
        let lines = [AITranscriptLineValue(
            speaker: "Host",
            text: "A generated line",
            startTime: 1,
            endTime: 2
        )]
        let encodedTranscript = try AIContentSyncCodec.encodeTranscript(lines)
        let transcriptID = StableIdentityKey.make(
            PodcastFeedIdentity.normalizedFeedURLString(feed),
            episodeID
        )
        cacheContext.insert(AITranscriptSync(
            feedURL: PodcastFeedIdentity.normalizedFeedURLString(feed),
            episodeID: episodeID,
            revisionID: encodedTranscript.revisionID,
            chunkCount: encodedTranscript.chunks.count,
            lineCount: encodedTranscript.lineCount,
            contentHash: encodedTranscript.contentHash,
            generatedAt: generatedAt
        ))
        for (index, payload) in encodedTranscript.chunks.enumerated() {
            cacheContext.insert(AITranscriptChunkSync(
                transcriptID: transcriptID,
                revisionID: encodedTranscript.revisionID,
                chunkIndex: index,
                payloadJSON: payload,
                contentHash: AIContentSyncCodec.sha256Hex(Data(payload.utf8))
            ))
        }

        let chapters = [AIChapterValue(
            title: "Generated chapter",
            startTime: 5,
            duration: 10,
            typeRawValue: MarkerType.ai.rawValue
        )]
        let encodedChapters = try AIContentSyncCodec.encodeChapters(chapters)
        cacheContext.insert(AIChapterSetSync(
            feedURL: PodcastFeedIdentity.normalizedFeedURLString(feed),
            episodeID: episodeID,
            revisionID: "chapter-revision",
            payloadJSON: encodedChapters.payload,
            chapterCount: chapters.count,
            contentHash: encodedChapters.hash,
            generatedAt: generatedAt
        ))
        let cacheEpisodeID = StableIdentityKey.make(
            PodcastFeedIdentity.normalizedFeedURLString(feed),
            episodeID
        )
        cacheContext.insert(CachedChapter(
            id: "cached-chapter",
            feedURL: PodcastFeedIdentity.normalizedFeedURLString(feed),
            episodeID: cacheEpisodeID,
            title: "Generated chapter",
            start: 5,
            duration: 10,
            progress: 0.4,
            typeRawValue: MarkerType.ai.rawValue,
            shouldPlay: false
        ))
        let legacyIdentity = legacyAIEpisode.stableEpisodeIdentity
        let legacyEpisodeKey = StableIdentityKey.make(legacyIdentity.feedURL, legacyIdentity.episodeID)
        cacheContext.insert(CachedTranscriptLine(
            id: UUID().uuidString,
            feedURL: PodcastFeedIdentity.normalizedFeedURLString(feed),
            episodeID: legacyIdentity.key,
            speaker: "Guest",
            text: "Legacy generated line",
            startTime: 3,
            sourceRawValue: CachedTranscriptSource.localAI.rawValue
        ))
        cacheContext.insert(CachedChapter(
            id: "legacy-ai-chapter",
            feedURL: PodcastFeedIdentity.normalizedFeedURLString(feed),
            episodeID: legacyEpisodeKey,
            title: "Legacy generated chapter",
            start: 8,
            duration: 12,
            progress: 0.6,
            typeRawValue: MarkerType.ai.rawValue,
            shouldPlay: false
        ))
        try cacheContext.save()

        let suiteName = "PodcastClient.aiMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertTrue(StoreSplitCacheAIContentMigration.migrate(
            cache: cache,
            library: library,
            defaults: defaults
        ))

        let migratedEpisodes = try ModelContext(library).fetch(FetchDescriptor<Episode>())
        let migratedEpisode = try XCTUnwrap(migratedEpisodes.first { $0.guid == "ai-fixture-guid" })
        let migratedLegacyEpisode = try XCTUnwrap(
            migratedEpisodes.first { $0.guid == "legacy-ai-fixture-guid" }
        )
        let transcript = try XCTUnwrap(migratedEpisode.transcriptLines?.first)
        XCTAssertEqual(transcript.text, "A generated line")
        let marker = try XCTUnwrap(migratedEpisode.chapters?.first)
        XCTAssertEqual(marker.title, "Generated chapter")
        XCTAssertEqual(marker.progress, 0.4)
        XCTAssertEqual(marker.shouldPlay, false)
        let legacyTranscript = try XCTUnwrap(migratedLegacyEpisode.transcriptLines?.first)
        XCTAssertEqual(legacyTranscript.text, "Legacy generated line")
        XCTAssertEqual(legacyTranscript.transcriptSource, .localAI)
        let legacyMarker = try XCTUnwrap(migratedLegacyEpisode.chapters?.first)
        XCTAssertEqual(legacyMarker.title, "Legacy generated chapter")
        XCTAssertEqual(legacyMarker.progress, 0.6)
        XCTAssertEqual(legacyMarker.shouldPlay, false)
        XCTAssertEqual(try cacheContext.fetchCount(FetchDescriptor<AITranscriptSync>()), 1)
        XCTAssertEqual(try cacheContext.fetchCount(FetchDescriptor<AIChapterSetSync>()), 1)
    }
}
