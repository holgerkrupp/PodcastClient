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
    func testSliceNeverProcessesEntireDatasetAtOnce() async throws {
        let containers = try makeContainers()
        try populate(containers.legacy, episodeCount: 130)

        let reports = await drainSlices(containers, shouldContinue: { true })

        // Several slices are required; no single slice does everything.
        XCTAssertGreaterThanOrEqual(reports.count, 9)
        XCTAssertEqual(reports.last?.status, .completed)

        let episodeSlices = reports.filter {
            $0.phase == "episode_states"
                && ($0.status == .advanced || $0.status == .phaseCompleted)
        }
        XCTAssertEqual(episodeSlices.count, 3, "130 episodes / 50 per page = 3 pages")
        for slice in episodeSlices {
            XCTAssertLessThanOrEqual(slice.processed, 50)
        }
        XCTAssertEqual(episodeSlices.reduce(0) { $0 + $1.processed }, 130)

        // Footprint telemetry is populated for every slice that did work.
        XCTAssertTrue(reports.allSatisfy { $0.footprintAfter > 0 })

        let counts = try destinationCounts(containers.userState)
        XCTAssertEqual(counts["episodeStates"], 130)
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
            cacheContainer: containers.cache,
            includeAIContent: false
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
            cacheContainer: containers.cache,
            includeAIContent: false
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
                    id: "v\(StoreSplitMigrationService.migrationVersion).\(phase)",
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
                    id: "v\(StoreSplitMigrationService.migrationVersion).\(phase)",
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
}
