import SwiftData
import XCTest
@testable import UpNext

/// A `shouldContinue` gate that permits a fixed number of `true` answers and then
/// reports `false`, used to simulate the migration being interrupted mid-slice.
private final class SliceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(_ remaining: Int) {
        self.remaining = remaining
    }

    func tick() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

final class StoreSplitSliceMigrationTests: XCTestCase {

    func testBackgroundMigrationScheduleUsesLocalNightAndDSTSafeNextWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let beforeNight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 18))!
        let duringNight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 23))!
        XCTAssertFalse(StoreSplitMigrationSchedulePolicy.isEligibleNight(beforeNight, calendar: calendar))
        XCTAssertTrue(StoreSplitMigrationSchedulePolicy.isEligibleNight(duringNight, calendar: calendar))
        XCTAssertEqual(
            StoreSplitMigrationSchedulePolicy.nextEligibleNightStart(after: beforeNight, calendar: calendar),
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 22))
        )
        XCTAssertEqual(
            StoreSplitMigrationSchedulePolicy.nextEligibleNightStart(after: duringNight, calendar: calendar),
            duringNight
        )
        let sizer = StoreSplitAdaptiveBatchSizer.shared
        XCTAssertEqual(sizer.pageSize(for: "adaptive-policy-test", base: 100, footprint: 100), 100)
        XCTAssertEqual(sizer.pageSize(for: "adaptive-policy-test", base: 100, footprint: 800 * 1_024 * 1_024), 50)
        sizer.recordPage("adaptive-policy-test", duration: 0.5)
        XCTAssertEqual(sizer.pageSize(for: "adaptive-policy-test", base: 100, footprint: 100), 150)
        XCTAssertLessThanOrEqual(StoreSplitMigrationRunPolicy.background.maximumActiveWorkTime, 30)
        XCTAssertGreaterThan(StoreSplitMigrationRunPolicy.background.maximumSlices, 3)
    }

    func testListeningStagesAreDispatchedBeforeHistoricalEpisodeSweep() {
        let phases = StoreSplitMigrationService.slicePhaseOrder
        XCTAssertLessThan(
            phases.firstIndex(of: "listening_summaries")!,
            phases.firstIndex(of: "episode_states")!
        )
        XCTAssertLessThan(
            phases.firstIndex(of: "listening_history")!,
            phases.firstIndex(of: "episode_states")!
        )
    }

    @MainActor
    func testLargeEpisodeFixtureAdvancesThousandsOfRowsWithinOneBackgroundWindow() async throws {
        let containers = try makeContainers()
        let source = containers.legacy.mainContext
        let podcast = Podcast(feed: URL(string: "https://example.com/performance.xml")!)
        podcast.title = "Performance fixture"
        source.insert(podcast)
        for index in 0..<14_000 {
            source.insert(Episode(
                guid: "performance-\(index)",
                title: "Episode \(index)",
                publishDate: Date(timeIntervalSince1970: Double(index)),
                url: URL(string: "https://example.com/performance/\(index).mp3")!,
                podcast: podcast,
                duration: 600
            ))
        }
        try source.save()

        let cache = containers.cache.mainContext
        for phase in ["subscriptions", "playlists", "playlist_entries", "bookmarks", "preferences", "listening_summaries", "listening_history"] {
            cache.insert(StoreSplitMigrationCheckpoint(
                id: StoreSplitMigrationService.checkpointID(for: phase),
                migrationVersion: StoreSplitMigrationService.migrationVersion,
                phase: phase,
                cursor: "0",
                completedAt: .now
            ))
        }
        try cache.save()

        var scanned = 0
        for _ in 0..<StoreSplitMigrationRunPolicy.background.maximumSlices {
            let report = await StoreSplitMigrationService.runSlice(
                legacyContainer: containers.legacy,
                userStateContainer: containers.userState,
                cacheContainer: containers.cache
            )
            XCTAssertNotEqual(report.status, .failed, report.error ?? "")
            scanned += report.processed
        }
        XCTAssertGreaterThanOrEqual(scanned, 2_000)
    }

    // MARK: - Helpers

    private struct Containers {
        let legacy: ModelContainer
        let userState: ModelContainer
        let cache: ModelContainer
    }

    @MainActor
    private func makeContainers() throws -> Containers {
        Containers(
            legacy: try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true),
            userState: try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true),
            cache: try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        )
    }

    /// Populates a legacy store with a deterministic dataset that exercises every
    /// non-AI phase, with enough episodes to require multiple episode-state pages.
    @MainActor
    private func populate(
        _ legacyContainer: ModelContainer,
        episodeCount: Int
    ) throws {
        let context = legacyContainer.mainContext
        let feedURL = URL(string: "https://example.com/feed.xml")!
        let podcast = Podcast(feed: feedURL)
        podcast.title = "Example"
        podcast.metaData?.isSubscribed = true
        podcast.metaData?.subscriptionDate = Date(timeIntervalSince1970: 1_000)
        context.insert(podcast)

        var episodes: [Episode] = []
        for index in 0..<episodeCount {
            let episode = Episode(
                guid: "episode-\(index)",
                title: "Episode \(index)",
                publishDate: Date(timeIntervalSince1970: Double(index) * 86_400),
                url: URL(string: "https://example.com/\(index).mp3")!,
                podcast: podcast,
                duration: 120
            )
            episode.metaData?.playPosition = Double(index + 1)
            episode.metaData?.maxPlayposition = Double(index + 2)
            episode.metaData?.lastPlayed = Date(timeIntervalSince1970: Double(index) * 100)
            episodes.append(episode)
            context.insert(episode)
        }
        podcast.episodes = episodes

        // A manual playlist plus the default "Up Next" queue, each with entries.
        let manual = Playlist()
        manual.title = "My List"
        manual.deleteable = true
        let queue = Playlist()
        queue.title = Playlist.defaultQueueTitle
        for (offset, playlist) in [manual, queue].enumerated() {
            var entries: [PlaylistEntry] = []
            for index in 0..<min(2, episodes.count) {
                let entry = PlaylistEntry(episode: episodes[index], order: index)
                entry.dateAdded = Date(timeIntervalSince1970: Double(offset * 10 + index))
                entry.playlist = playlist
                entries.append(entry)
            }
            playlist.items = entries
            context.insert(playlist)
        }

        if let first = episodes.first {
            let bookmark = Bookmark(start: 30, title: "Remember", type: .bookmark)
            bookmark.uuid = UUID()
            bookmark.creationtime = Date(timeIntervalSince1970: 5_000)
            bookmark.bookmarkEpisode = first
            first.bookmarks = [bookmark]
            context.insert(bookmark)

            let session = PlaySession(
                id: UUID(),
                episode: first,
                startTime: Date(timeIntervalSince1970: 3_000),
                endTime: Date(timeIntervalSince1970: 3_120),
                startPosition: 0,
                endPosition: 120,
                endedCleanly: true
            )
            context.insert(session)
        }

        let summary = PlaySessionSummary(
            id: UUID(),
            periodKind: PlaySessionSummaryPeriod.week.rawValue,
            periodStart: Date(timeIntervalSince1970: 0),
            podcastFeed: feedURL,
            podcastName: "Example",
            totalSeconds: 120,
            silenceGapTimeSavedSeconds: 5,
            playbackRateTimeSavedSeconds: 0,
            activeHourCount: 1
        )
        context.insert(summary)

        try context.save()
    }

    @MainActor
    @discardableResult
    private func drainSlices(
        _ containers: Containers,
        shouldContinue: @escaping @Sendable () -> Bool,
        maxSlices: Int = 2_000
    ) async -> [StoreSplitSliceReport] {
        var reports: [StoreSplitSliceReport] = []
        for _ in 0..<maxSlices {
            let report = await StoreSplitMigrationService.runSlice(
                legacyContainer: containers.legacy,
                userStateContainer: containers.userState,
                cacheContainer: containers.cache,
                shouldContinue: shouldContinue
            )
            reports.append(report)
            switch report.status {
            case .completed, .cancelled, .failed:
                return reports
            case .advanced, .phaseCompleted:
                continue
            }
        }
        return reports
    }

    @MainActor
    private func destinationCounts(_ container: ModelContainer) throws -> [String: Int] {
        let context = ModelContext(container)
        return [
            "subscriptions": try context.fetchCount(FetchDescriptor<SubscriptionSync>()),
            "episodeStates": try context.fetchCount(FetchDescriptor<EpisodeStateSync>()),
            "playlists": try context.fetchCount(FetchDescriptor<PlaylistSync>()),
            "playlistEntries": try context.fetchCount(FetchDescriptor<PlaylistEntrySync>()),
            "queueEntries": try context.fetchCount(FetchDescriptor<QueueEntrySync>()),
            "bookmarks": try context.fetchCount(FetchDescriptor<BookmarkSync>()),
            "listeningHistory": try context.fetchCount(FetchDescriptor<ListeningHistorySync>()),
            "listeningBaselines": try context.fetchCount(FetchDescriptor<ListeningBaselineSync>())
        ]
    }

    // MARK: - Tests

    @MainActor
    func testAuthoritativeReconciliationPreservesUnprovenDestinationOnlyState() async throws {
        let containers = try makeContainers()
        try populate(containers.legacy, episodeCount: 3)

        let userContext = containers.userState.mainContext
        userContext.insert(
            SubscriptionSync(
                feedURL: "https://stale.example/feed.xml",
                isSubscribed: true
            )
        )
        userContext.insert(
            PlaylistSync(
                id: "stale-playlist",
                title: "Stale playlist",
                symbolName: "archivebox",
                sortIndex: 99,
                kindRawValue: "manual"
            )
        )
        userContext.insert(
            PlaylistEntrySync(
                playlistID: "stale-playlist",
                feedURL: "https://stale.example/feed.xml",
                episodeID: "stale-episode",
                sortIndex: 0
            )
        )
        userContext.insert(
            QueueEntrySync(
                feedURL: "https://stale.example/feed.xml",
                episodeID: "stale-episode",
                sortIndex: 0
            )
        )
        userContext.insert(
            BookmarkSync(
                id: "stale-bookmark",
                feedURL: "https://stale.example/feed.xml",
                episodeID: "stale-episode",
                time: 10
            )
        )
        userContext.insert(PodcastPreferenceSync(feedURL: "https://stale.example/feed.xml"))
        userContext.insert(
            EpisodeStateSync(
                feedURL: "https://stale.example/feed.xml",
                episodeID: "stale-episode",
                playPosition: 10
            )
        )
        try userContext.save()

        let result = await StoreSplitAuthoritativeReconciliationService.reconcile(
            legacyContainer: containers.legacy,
            userStateContainer: containers.userState
        )

        XCTAssertEqual(result.failed, 1)
        XCTAssertNotNil(result.error)

        let subscription = try XCTUnwrap(
            try userContext.fetch(FetchDescriptor<SubscriptionSync>())
                .first { $0.id == "https://stale.example/feed.xml" }
        )
        XCTAssertTrue(subscription.isSubscribed)
        XCTAssertTrue(
            try userContext.fetch(FetchDescriptor<PlaylistSync>())
                .first { $0.id == "stale-playlist" }?.isDeleted == false
        )
        XCTAssertTrue(
            try userContext.fetch(FetchDescriptor<PlaylistEntrySync>())
                .first { $0.id == StableIdentityKey.make(
                    "stale-playlist",
                    "https://stale.example/feed.xml",
                    "stale-episode"
                ) }?.isDeleted == false
        )
        XCTAssertTrue(
            try userContext.fetch(FetchDescriptor<QueueEntrySync>())
                .first { $0.id == StableIdentityKey.make(
                    "https://stale.example/feed.xml",
                    "stale-episode"
                ) }?.isDeleted == false
        )
        XCTAssertTrue(
            try userContext.fetch(FetchDescriptor<BookmarkSync>())
                .first { $0.id == "stale-bookmark" }?.isDeleted == false
        )
        XCTAssertTrue(
            try userContext.fetch(FetchDescriptor<PodcastPreferenceSync>())
                .contains { $0.feedURL == "https://stale.example/feed.xml" }
        )
        XCTAssertTrue(
            try userContext.fetch(FetchDescriptor<EpisodeStateSync>())
                .contains { $0.feedURL == "https://stale.example/feed.xml" }
        )
    }

    @MainActor
    func testBookmarkPhasePagesBookmarksNotTheChapterTable() async throws {
        let containers = try makeContainers()
        try populate(containers.legacy, episodeCount: 3)

        let context = containers.legacy.mainContext
        let firstEpisode = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Episode>())
                .first { $0.bookmarks?.isEmpty == false }
        )

        // `Bookmark` is a subclass of `Marker`, and `Marker` is also the chapter
        // model. A real library holds orders of magnitude more chapters than
        // bookmarks, and the bookmarks phase must not walk them: paging the
        // base table made every slice re-sort the whole chapter table.
        var chapters = firstEpisode.chapters ?? []
        for index in 0..<500 {
            let chapter = Marker(
                start: Double(index),
                title: "Chapter \(index)",
                type: .podlove
            )
            chapter.creationtime = Date(timeIntervalSince1970: Double(index))
            chapter.episode = firstEpisode
            chapters.append(chapter)
            context.insert(chapter)
        }
        firstEpisode.chapters = chapters

        // Two more bookmarks on top of the one `populate` creates.
        var bookmarks = firstEpisode.bookmarks ?? []
        for index in 0..<2 {
            let bookmark = Bookmark(
                start: Double(index),
                title: "Mark \(index)",
                type: .bookmark
            )
            bookmark.uuid = UUID()
            bookmark.creationtime = Date(timeIntervalSince1970: Double(6_000 + index))
            bookmark.bookmarkEpisode = firstEpisode
            bookmarks.append(bookmark)
            context.insert(bookmark)
        }
        firstEpisode.bookmarks = bookmarks
        try context.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Marker>()), 503)

        let reports = await drainSlices(containers, shouldContinue: { true })
        XCTAssertEqual(reports.last?.status, .completed)

        let bookmarkSlices = reports.filter {
            $0.phase == "bookmarks"
                && ($0.status == .advanced || $0.status == .phaseCompleted)
        }
        XCTAssertEqual(
            bookmarkSlices.reduce(0) { $0 + $1.processed },
            3,
            "the phase must page the 3 bookmarks, not the 503-row Marker table"
        )
        XCTAssertEqual(
            bookmarkSlices.count,
            1,
            "3 bookmarks fit in a single page"
        )

        let counts = try destinationCounts(containers.userState)
        XCTAssertEqual(counts["bookmarks"], 3)
    }

    @MainActor
    func testAutomaticSlicesBackfillAIContentIntoPodcastCache() async throws {
        let containers = try makeContainers()
        let feedURL = URL(string: "https://example.com/ai-feed.xml")!
        let episodeURL = URL(string: "https://example.com/ai-episode.mp3")!
        let podcast = Podcast(feed: feedURL)
        let episode = Episode(
            guid: "ai-backfill",
            title: "AI backfill",
            url: episodeURL,
            podcast: podcast
        )
        let line = TranscriptLineAndTime(
            speaker: "Host",
            text: "A recoverable transcript line",
            startTime: 12,
            endTime: 18
        )
        line.episode = episode
        episode.transcriptLines = [line]
        let chapter = Marker(start: 12, title: "AI chapter", type: .ai)
        chapter.duration = 30
        chapter.creationtime = Date(timeIntervalSince1970: 2_000)
        chapter.analysisVariantID = "media-revision"
        chapter.episode = episode
        episode.chapters = [chapter]
        podcast.episodes = [episode]
        containers.legacy.mainContext.insert(podcast)
        containers.legacy.mainContext.insert(
            TranscriptionRecord(
                episodeURL: episodeURL,
                episodeTitle: episode.title,
                podcastTitle: "Example",
                localeIdentifier: "en",
                startedAt: Date(timeIntervalSince1970: 1_900),
                finishedAt: Date(timeIntervalSince1970: 2_000),
                audioDuration: 30
            )
        )
        try containers.legacy.mainContext.save()

        var completed = false
        for _ in 0..<30 {
            let report = await StoreSplitMigrationService.runSlice(
                legacyContainer: containers.legacy,
                userStateContainer: containers.userState,
                cacheContainer: containers.cache,
                shouldContinue: { true }
            )
            if report.status == .failed {
                XCTFail("AI migration slice failed: \(report.error ?? "unknown error")")
                return
            }
            if report.status == .completed {
                completed = true
                break
            }
        }

        XCTAssertTrue(completed, "bounded migration slices should finish every phase")
        let cache = containers.cache.mainContext
        let transcript = try XCTUnwrap(
            try cache.fetch(FetchDescriptor<AITranscriptSync>()).first
        )
        let chunks = try cache.fetch(FetchDescriptor<AITranscriptChunkSync>())
            .filter { $0.transcriptID == transcript.id }
            .sorted { $0.chunkIndex < $1.chunkIndex }
        let decodedLines = try AIContentSyncCodec.decodeTranscript(
            chunks: chunks.map(\.payloadJSON),
            expectedLineCount: transcript.lineCount,
            expectedContentHash: transcript.contentHash
        )
        XCTAssertEqual(decodedLines.map(\.text), ["A recoverable transcript line"])

        let chapterSet = try XCTUnwrap(
            try cache.fetch(FetchDescriptor<AIChapterSetSync>()).first
        )
        let decodedChapters = try AIContentSyncCodec.decodeChapters(
            payloadJSON: chapterSet.payloadJSON,
            expectedContentHash: chapterSet.contentHash
        )
        XCTAssertEqual(decodedChapters.first?.title, "AI chapter")
        XCTAssertEqual(decodedChapters.first?.analysisVariantID, "media-revision")
    }

    @MainActor
    func testSliceNeverProcessesEntireDatasetAtOnce() async throws {
        let containers = try makeContainers()
        try populate(containers.legacy, episodeCount: 300)

        let reports = await drainSlices(containers, shouldContinue: { true })

        // Several slices are required; no single slice does everything.
        XCTAssertGreaterThanOrEqual(reports.count, 9)
        XCTAssertEqual(reports.last?.status, .completed)

        let episodeSlices = reports.filter {
            $0.phase == "episode_states"
                && ($0.status == .advanced || $0.status == .phaseCompleted)
        }
        XCTAssertGreaterThan(episodeSlices.count, 1)
        for slice in episodeSlices {
            XCTAssertLessThanOrEqual(
                slice.processed,
                StoreWorkBudget.migrationSlice.maximumMutations
            )
        }
        XCTAssertEqual(episodeSlices.reduce(0) { $0 + $1.processed }, 300)

        // Footprint telemetry is populated for every slice that did work.
        XCTAssertTrue(reports.allSatisfy { $0.footprintAfter > 0 })

        let counts = try destinationCounts(containers.userState)
        XCTAssertEqual(counts["episodeStates"], 300)
        XCTAssertEqual(counts["subscriptions"], 1)
        XCTAssertEqual(counts["playlists"], 2)
        XCTAssertEqual(counts["queueEntries"], 2)
        XCTAssertEqual(counts["bookmarks"], 1)
        XCTAssertEqual(counts["listeningHistory"], 1)
        XCTAssertEqual(counts["listeningBaselines"], 1)
    }

    @MainActor
    func testSliceMigrationMatchesWholeRun() async throws {
        let sliced = try makeContainers()
        try populate(sliced.legacy, episodeCount: 75)
        await drainSlices(sliced, shouldContinue: { true })

        let wholeRun = try makeContainers()
        try populate(wholeRun.legacy, episodeCount: 75)
        _ = await StoreSplitMigrationService.migrate(
            legacyContainer: wholeRun.legacy,
            userStateContainer: wholeRun.userState,
            cacheContainer: wholeRun.cache,
            includeAIContent: false
        )

        XCTAssertEqual(
            try destinationCounts(sliced.userState),
            try destinationCounts(wholeRun.userState)
        )
    }

    @MainActor
    func testInterruptedSliceMigrationResumesToSameResult() async throws {
        let interrupted = try makeContainers()
        try populate(interrupted.legacy, episodeCount: 120)

        // Stop after a handful of `true` answers, simulating playback/background.
        let gate = SliceGate(40)
        let partial = await drainSlices(interrupted, shouldContinue: { gate.tick() })
        XCTAssertEqual(partial.last?.status, .cancelled)
        let partialEpisodeStates = try destinationCounts(interrupted.userState)["episodeStates"]
        XCTAssertNotNil(partialEpisodeStates)
        XCTAssertLessThan(partialEpisodeStates ?? .max, 120)

        // Resume with no interruption; the cursor continues from where it stopped.
        let resumed = await drainSlices(interrupted, shouldContinue: { true })
        XCTAssertEqual(resumed.last?.status, .completed)

        let reference = try makeContainers()
        try populate(reference.legacy, episodeCount: 120)
        _ = await StoreSplitMigrationService.migrate(
            legacyContainer: reference.legacy,
            userStateContainer: reference.userState,
            cacheContainer: reference.cache,
            includeAIContent: false
        )

        XCTAssertEqual(
            try destinationCounts(interrupted.userState),
            try destinationCounts(reference.userState)
        )
    }

    @MainActor
    func testSliceMigrationIsIdempotentAcrossReruns() async throws {
        let containers = try makeContainers()
        try populate(containers.legacy, episodeCount: 60)

        await drainSlices(containers, shouldContinue: { true })
        let firstPass = try destinationCounts(containers.userState)

        // A second full run via the whole-run entry point must not duplicate.
        _ = await StoreSplitMigrationService.migrate(
            legacyContainer: containers.legacy,
            userStateContainer: containers.userState,
            cacheContainer: containers.cache
        )
        let secondPass = try destinationCounts(containers.userState)

        XCTAssertEqual(firstPass, secondPass)
    }

    @MainActor
    func testIsSliceMigrationCompleteReflectsProgress() async throws {
        let containers = try makeContainers()
        try populate(containers.legacy, episodeCount: 60)

        XCTAssertFalse(
            StoreSplitMigrationService.isSliceMigrationComplete(
                cacheContainer: containers.cache
            )
        )

        _ = await StoreSplitMigrationService.migrate(
            legacyContainer: containers.legacy,
            userStateContainer: containers.userState,
            cacheContainer: containers.cache
        )

        XCTAssertTrue(
            StoreSplitMigrationService.isSliceMigrationComplete(
                cacheContainer: containers.cache
            )
        )
    }

    func testRolloutResolvedModeMapping() {
        StoreSplitRollout.resetForDevelopment()
        defer { StoreSplitRollout.resetForDevelopment() }

        XCTAssertEqual(StoreSplitRollout.state, .unclassified)
        XCTAssertEqual(StoreSplitRollout.resolvedMode, .splitStores)

        StoreSplitRollout.set(.migrating)
        XCTAssertEqual(StoreSplitRollout.resolvedMode, .splitStores)

        StoreSplitRollout.set(.newStoreReads)
        // The backfill release records migration completion but must not change
        // how the app reads; only the authority release maps it to split reads.
        XCTAssertEqual(
            StoreSplitRollout.resolvedMode,
            StoreSplitReleasePhase.current == .userStateAuthority
                ? .splitStoreReads
                : .splitStores
        )
    }

    @MainActor
    func testCompletedMigrationPreflightPromotesRolloutToNewStoreReads() throws {
        StoreSplitRollout.resetForDevelopment()
        defer { StoreSplitRollout.resetForDevelopment() }
        let containers = try makeContainers()
        let context = containers.cache.mainContext

        for phase in StoreSplitMigrationService.slicePhaseOrder {
            context.insert(
                StoreSplitMigrationCheckpoint(
                    id: StoreSplitMigrationService.checkpointID(for: phase),
                    migrationVersion: StoreSplitMigrationService.migrationVersion,
                    phase: phase,
                    completedAt: Date(timeIntervalSince1970: 1_000),
                    scannedCount: 1
                )
            )
        }
        let verification = StoreSplitMigrationVerification(
            id: StoreSplitMigrationVerifier.verificationID,
            migrationVersion: StoreSplitMigrationService.migrationVersion
        )
        verification.verifiedAt = Date(timeIntervalSince1970: 1_001)
        verification.cacheMissingCount = 0
        verification.issues = []
        context.insert(verification)
        try context.save()

        XCTAssertTrue(
            ModelContainerManager.promoteRolloutForCompletedSplitStoreMigrationIfNeeded(
                cacheContainer: containers.cache
            )
        )
        XCTAssertEqual(StoreSplitRollout.state, .newStoreReads)
        XCTAssertEqual(
            StoreSplitRollout.resolvedMode,
            StoreSplitReleasePhase.current == .userStateAuthority
                ? .splitStoreReads
                : .splitStores
        )
    }

    @MainActor
    func testIncompleteMigrationPreflightDoesNotPromoteRollout() throws {
        StoreSplitRollout.resetForDevelopment()
        defer { StoreSplitRollout.resetForDevelopment() }
        let containers = try makeContainers()
        let context = containers.cache.mainContext

        for phase in StoreSplitMigrationService.slicePhaseOrder.dropLast() {
            context.insert(
                StoreSplitMigrationCheckpoint(
                    id: StoreSplitMigrationService.checkpointID(for: phase),
                    migrationVersion: StoreSplitMigrationService.migrationVersion,
                    phase: phase,
                    completedAt: Date(timeIntervalSince1970: 1_000),
                    scannedCount: 1
                )
            )
        }
        try context.save()

        XCTAssertFalse(
            ModelContainerManager.promoteRolloutForCompletedSplitStoreMigrationIfNeeded(
                cacheContainer: containers.cache
            )
        )
        XCTAssertEqual(StoreSplitRollout.state, .unclassified)
        XCTAssertEqual(StoreSplitRollout.resolvedMode, .splitStores)
    }

    @MainActor
    func testCancellationBeforeWorkReportsCancelled() async throws {
        let containers = try makeContainers()
        try populate(containers.legacy, episodeCount: 10)

        let report = await StoreSplitMigrationService.runSlice(
            legacyContainer: containers.legacy,
            userStateContainer: containers.userState,
            cacheContainer: containers.cache,
            shouldContinue: { false }
        )

        XCTAssertEqual(report.status, .cancelled)
        XCTAssertEqual(try destinationCounts(containers.userState)["subscriptions"], 0)
    }

    @MainActor
    func testListeningSummaryMigrationSynthesizesForeverRollup() async throws {
        let containers = try makeContainers()
        let context = containers.legacy.mainContext
        let feedA = URL(string: "https://example.com/a.xml")!
        let feedB = URL(string: "https://example.com/b.xml")!

        func summary(
            _ feed: URL,
            kind: PlaySessionSummaryPeriod,
            year: Int,
            seconds: Double
        ) -> PlaySessionSummary {
            PlaySessionSummary(
                id: UUID(),
                periodKind: kind.rawValue,
                periodStart: Calendar.current.date(from: DateComponents(year: year))!,
                podcastFeed: feed,
                podcastName: feed.lastPathComponent,
                totalSeconds: seconds,
                silenceGapTimeSavedSeconds: 0,
                playbackRateTimeSavedSeconds: 0,
                activeHourCount: 1
            )
        }

        // Two years of `.year` summaries for feed A, one for feed B, plus a `.month`
        // row that must NOT contribute to the forever rollup (it overlaps the year).
        context.insert(summary(feedA, kind: .year, year: 2023, seconds: 3_600))
        context.insert(summary(feedA, kind: .year, year: 2024, seconds: 1_800))
        context.insert(summary(feedA, kind: .month, year: 2024, seconds: 1_800))
        context.insert(summary(feedB, kind: .year, year: 2024, seconds: 600))
        try context.save()

        await drainSlices(containers, shouldContinue: { true })

        let destination = ModelContext(containers.userState)
        let baselines = try destination.fetch(FetchDescriptor<ListeningBaselineSync>())

        // One frozen row per feed, each summed only from that feed's `.year`
        // rows. The `.month` row overlaps a year it is already inside, so
        // including it would double-count.
        XCTAssertEqual(baselines.map(\.totalSeconds).sorted(), [600, 5_400])
        XCTAssertEqual(baselines.reduce(0) { $0 + $1.totalSeconds }, 6_000)
    }

    @MainActor
    func testLargeListeningSummaryAggregationIsPagedAndPublishesOnlyFinalTotals() async throws {
        let containers = try makeContainers()
        let context = containers.legacy.mainContext
        let feed = URL(string: "https://example.com/large.xml")!
        for index in 0..<2_679 {
            context.insert(PlaySessionSummary(
                id: UUID(),
                periodKind: PlaySessionSummaryPeriod.year.rawValue,
                periodStart: Date(timeIntervalSince1970: Double(index)),
                podcastFeed: feed,
                podcastName: "Large fixture",
                totalSeconds: 10,
                silenceGapTimeSavedSeconds: 2,
                playbackRateTimeSavedSeconds: 1,
                activeHourCount: 1
            ))
        }
        try context.save()

        var reachedSummary = false
        var firstSummaryPage: StoreSplitSliceReport?
        for _ in 0..<20 {
            let report = await StoreSplitMigrationService.runSlice(
                legacyContainer: containers.legacy,
                userStateContainer: containers.userState,
                cacheContainer: containers.cache
            )
            if report.phase == "listening_summaries" {
                reachedSummary = true
                firstSummaryPage = report
                break
            }
        }
        XCTAssertTrue(reachedSummary)
        XCTAssertEqual(firstSummaryPage?.status, .advanced)
        XCTAssertGreaterThan(firstSummaryPage?.processed ?? 0, 0)
        XCTAssertLessThanOrEqual(firstSummaryPage?.processed ?? Int.max, 300)
        XCTAssertEqual(try destinationCounts(containers.userState)["listeningBaselines"], 0)

        let reports = await drainSlices(containers, shouldContinue: { true })
        XCTAssertFalse(reports.contains { $0.status == .failed })
        let baseline = try XCTUnwrap(
            ModelContext(containers.userState)
                .fetch(FetchDescriptor<ListeningBaselineSync>())
                .first
        )
        XCTAssertEqual(baseline.totalSeconds, 26_790, accuracy: 0.001)
        XCTAssertEqual(baseline.silenceGapTimeSavedSeconds, 5_358, accuracy: 0.001)
        XCTAssertEqual(baseline.playbackRateTimeSavedSeconds, 2_679, accuracy: 0.001)
    }

    /// The legacy store stays live while slices run, so a row deleted between
    /// slices shifts every later row down. A bare offset cursor would step over
    /// exactly one unmigrated row per deletion and still call the phase complete.
    @MainActor
    func testDeletionBetweenSlicesDoesNotSkipUnmigratedRows() async throws {
        let containers = try makeContainers()
        try populate(containers.legacy, episodeCount: 130)

        // Run slices until the episode-state phase has committed its first page.
        var advancedEpisodePages = 0
        while advancedEpisodePages == 0 {
            let report = await StoreSplitMigrationService.runSlice(
                legacyContainer: containers.legacy,
                userStateContainer: containers.userState,
                cacheContainer: containers.cache,
                shouldContinue: { true }
            )
            XCTAssertNotEqual(report.status, .failed)
            if report.phase == "episode_states", report.processed > 0 {
                advancedEpisodePages += 1
            }
        }

        // Delete an episode the first page already migrated. Episodes page by
        // descending publish date, so this is the very first row.
        let legacy = containers.legacy.mainContext
        let newest = try XCTUnwrap(
            legacy.fetch(
                FetchDescriptor<Episode>(
                    predicate: #Predicate { $0.guid == "episode-129" }
                )
            ).first
        )
        legacy.delete(newest)
        try legacy.save()

        await drainSlices(containers, shouldContinue: { true })

        // Every episode that still exists has a state row. Counting rows is not
        // enough: the deleted episode's own row stays behind in the destination
        // and would mask a skipped episode one-for-one.
        let remaining = try legacy.fetch(FetchDescriptor<Episode>())
        let expected = Set(remaining.map(\.stableEpisodeIdentity.key))
        let migrated = Set(
            try ModelContext(containers.userState)
                .fetch(FetchDescriptor<EpisodeStateSync>())
                .map(\.id)
        )
        XCTAssertEqual(remaining.count, 129)
        XCTAssertEqual(expected.subtracting(migrated), [])
    }

    /// Deleting the very row the cursor was taken from cannot strand the phase:
    /// it re-scans once, which is safe because every write is idempotent, and it
    /// still reaches completion.
    @MainActor
    func testDeletingTheBoundaryRowRescansAndStillCompletes() async throws {
        let containers = try makeContainers()
        try populate(containers.legacy, episodeCount: 130)

        var sawEpisodePage = false
        while sawEpisodePage == false {
            let report = await StoreSplitMigrationService.runSlice(
                legacyContainer: containers.legacy,
                userStateContainer: containers.userState,
                cacheContainer: containers.cache,
                shouldContinue: { true }
            )
            XCTAssertNotEqual(report.status, .failed)
            sawEpisodePage = report.phase == "episode_states" && report.processed > 0
        }

        // Episodes page newest-first, so the first page ends at episode-80 — the
        // row the checkpoint pinned itself to.
        let legacy = containers.legacy.mainContext
        let boundary = try XCTUnwrap(
            legacy.fetch(
                FetchDescriptor<Episode>(
                    predicate: #Predicate { $0.guid == "episode-80" }
                )
            ).first
        )
        legacy.delete(boundary)
        try legacy.save()

        let reports = await drainSlices(containers, shouldContinue: { true })
        XCTAssertEqual(reports.last?.status, .completed)

        let remaining = try legacy.fetch(FetchDescriptor<Episode>())
        let migrated = Set(
            try ModelContext(containers.userState)
                .fetch(FetchDescriptor<EpisodeStateSync>())
                .map(\.id)
        )
        XCTAssertEqual(
            Set(remaining.map(\.stableEpisodeIdentity.key)).subtracting(migrated), []
        )
    }

    @MainActor
    func testDormantDeviceBackfillDoesNotRewindNewerCloudPlaybackState() async throws {
        let dormantDevice = try makeContainers()
        try populate(dormantDevice.legacy, episodeCount: 1)

        let legacyContext = dormantDevice.legacy.mainContext
        let legacyEpisode = try XCTUnwrap(
            legacyContext.fetch(
                FetchDescriptor<Episode>(
                    predicate: #Predicate { $0.guid == "episode-0" }
                )
            ).first
        )
        let legacyDate = Date(timeIntervalSince1970: 4_000)
        legacyEpisode.metaData?.stateUpdatedAt = legacyDate
        legacyEpisode.metaData?.playPosition = 25
        legacyEpisode.metaData?.maxPlayposition = 25
        try legacyContext.save()

        // Represents a newer CloudKit import that reached this device while its
        // local legacy snapshot was dormant and stale.
        let remoteDate = Date(timeIntervalSince1970: 9_000)
        let identity = legacyEpisode.stableEpisodeIdentity
        let identityKey = identity.key
        let userContext = dormantDevice.userState.mainContext
        userContext.insert(
            EpisodeStateSync(
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                playPosition: 180,
                maxPlayPosition: 240,
                duration: 300,
                updatedAt: remoteDate,
                sourceDeviceID: "active-device"
            )
        )
        try userContext.save()

        let reports = await drainSlices(dormantDevice, shouldContinue: { true })
        XCTAssertEqual(reports.last?.status, .completed)

        let stored = try XCTUnwrap(
            ModelContext(dormantDevice.userState)
                .fetch(
                    FetchDescriptor<EpisodeStateSync>(
                        predicate: #Predicate { $0.id == identityKey }
                    )
                ).first
        )
        XCTAssertEqual(stored.playPosition, 180)
        XCTAssertEqual(stored.maxPlayPosition, 240)
        XCTAssertEqual(stored.updatedAt, remoteDate)
        XCTAssertEqual(stored.sourceDeviceID, "active-device")
    }

#if DEBUG
    func testDebugAutomaticChecksHaveNoFailedSyntheticScenarios() async {
        let results = await StoreSplitAutomaticChecks.runAll()
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(
            results.allSatisfy { $0.status != .failed },
            results.map { "\($0.id): \($0.details)" }.joined(separator: "\n")
        )
        XCTAssertTrue(results.contains { $0.id == "204" && $0.status == .partial })
        XCTAssertTrue(results.contains { $0.id == "205" && $0.status == .partial })
    }
#endif

    /// Verification has to compare legacy summaries against the baselines they
    /// actually migrate into. Comparing them against a bucket nothing writes made
    /// `missing_listening_summaries` permanent, which pinned the cleanup gate shut
    /// for every user with listening history.
    @MainActor
    func testVerificationPassesAfterListeningBaselineMigration() async throws {
        let containers = try makeContainers()
        try populate(containers.legacy, episodeCount: 5)

        await drainSlices(containers, shouldContinue: { true })

        let report = StoreSplitMigrationVerifier.verify(
            legacyContainer: containers.legacy,
            userStateContainer: containers.userState,
            cacheContainer: containers.cache
        )
        XCTAssertGreaterThan(
            try destinationCounts(containers.userState)["listeningBaselines"] ?? 0, 0
        )
        XCTAssertEqual(
            report.issues.filter { $0.hasPrefix("missing_listening") }, []
        )
        let gate = StoreSplitMigrationVerifier.cleanupGate(
            cacheContainer: containers.cache,
            legacyFallbackDisabled: true,
            convergenceTelemetryPassed: true,
            gracePeriodEnd: .distantPast
        )
        XCTAssertTrue(gate.migrationVerified, "issues: \(report.issues)")
    }

    @MainActor
    func testMigrationDiagnosticsMatchAutomaticSliceEngine() async throws {
        let containers = try makeContainers()
        try populate(containers.legacy, episodeCount: 5)

        var status = StoreSplitMigrationDiagnostics.migrationStatus(
            cacheContext: containers.cache.mainContext,
            userStateContext: containers.userState.mainContext,
            isRunning: false,
            readiness: .ready
        )
        XCTAssertEqual(status.completedPhaseCount, 0)
        XCTAssertEqual(
            status.totalPhaseCount,
            StoreSplitMigrationService.slicePhaseOrder.count
        )
        XCTAssertFalse(status.isComplete)

        let reports = await drainSlices(containers, shouldContinue: { true })
        let last = try XCTUnwrap(reports.last)
        status = StoreSplitMigrationDiagnostics.migrationStatus(
            cacheContext: containers.cache.mainContext,
            userStateContext: containers.userState.mainContext,
            isRunning: false,
            readiness: .complete,
            lastSliceStatus: last.status,
            lastSliceProcessed: last.processed,
            lastSliceError: last.error
        )
        XCTAssertEqual(status.lastSliceStatus, .completed)
        XCTAssertEqual(status.lastSliceError, nil)
        XCTAssertTrue(status.isComplete)
        XCTAssertEqual(status.completedPhaseCount, status.totalPhaseCount)
    }

    @MainActor
    func testNoSourceCompletionCreatesTruthfulCheckpoints() throws {
        let containers = try makeContainers()
        StoreSplitMigrationService.markMigrationCompleteWithoutSource(
            cacheContainer: containers.cache
        )

        let status = StoreSplitMigrationDiagnostics.migrationStatus(
            cacheContext: containers.cache.mainContext,
            userStateContext: containers.userState.mainContext,
            isRunning: false,
            readiness: .complete
        )
        XCTAssertEqual(status.completedPhaseCount, status.totalPhaseCount)
        XCTAssertTrue(status.isComplete)
        XCTAssertTrue(
            StoreSplitMigrationService.isSliceMigrationComplete(
                cacheContainer: containers.cache
            )
        )
    }

    @MainActor
    func testDualSyncBackfillConvergesTwoReleaseEquivalentDevicesBeforeCutover() async throws {
        XCTAssertEqual(
            StoreSplitReleasePhase.current,
            .dualSyncBackfill,
            "the release-equivalent test must exercise ship one"
        )

        let firstDevice = try makeContainers()
        let secondDevice = try makeContainers()
        try populate(firstDevice.legacy, episodeCount: 12)
        try populate(secondDevice.legacy, episodeCount: 12)

        let firstReports = await drainSlices(firstDevice, shouldContinue: { true })
        let secondReports = await drainSlices(secondDevice, shouldContinue: { true })
        XCTAssertEqual(firstReports.last?.status, .completed)
        XCTAssertEqual(secondReports.last?.status, .completed)

        let coldGate = StoreSplitMigrationVerifier.cutoverGate(
            legacyContainer: firstDevice.legacy,
            cacheContainer: firstDevice.cache,
            allDevicesConverged: true,
            delayedCloudImportsSettled: true
        )
        XCTAssertFalse(StoreSplitReleasePhase.canSwitchToUserStateAuthority(gate: coldGate))
        XCTAssertTrue(coldGate.blockers.contains("PodcastCache is not ready"))

        XCTAssertEqual(
            StoreSplitFeedCacheWriter.bootstrapMissingFeeds(
                legacyContainer: firstDevice.legacy,
                cacheContainer: firstDevice.cache,
                limit: 50
            ),
            1
        )
        XCTAssertEqual(
            StoreSplitFeedCacheWriter.bootstrapMissingFeeds(
                legacyContainer: secondDevice.legacy,
                cacheContainer: secondDevice.cache,
                limit: 50
            ),
            1
        )
        XCTAssertEqual(
            try destinationCounts(firstDevice.userState),
            try destinationCounts(secondDevice.userState)
        )
        // The cutover gate requires a recorded lossless verification, not just
        // completed migration cursors and a populated feed cache.
        XCTAssertTrue(StoreSplitMigrationVerifier.verify(
            legacyContainer: firstDevice.legacy,
            userStateContainer: firstDevice.userState,
            cacheContainer: firstDevice.cache
        ).isLossless)
        XCTAssertTrue(StoreSplitMigrationVerifier.verify(
            legacyContainer: secondDevice.legacy,
            userStateContainer: secondDevice.userState,
            cacheContainer: secondDevice.cache
        ).isLossless)

        let firstGate = StoreSplitMigrationVerifier.cutoverGate(
            legacyContainer: firstDevice.legacy,
            cacheContainer: firstDevice.cache,
            allDevicesConverged: false,
            delayedCloudImportsSettled: true
        )
        XCTAssertFalse(StoreSplitReleasePhase.canSwitchToUserStateAuthority(gate: firstGate))
        XCTAssertTrue(firstGate.blockers.contains("devices have not converged"))

        let convergedGate = StoreSplitMigrationVerifier.cutoverGate(
            legacyContainer: firstDevice.legacy,
            cacheContainer: firstDevice.cache,
            allDevicesConverged: true,
            delayedCloudImportsSettled: true
        )
        XCTAssertTrue(
            StoreSplitReleasePhase.canSwitchToUserStateAuthority(gate: convergedGate),
            "authority cutover requires both devices to finish the dual-sync backfill"
        )
    }
}
