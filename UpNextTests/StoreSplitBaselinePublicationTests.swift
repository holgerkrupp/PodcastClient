import Foundation
import SwiftData
import XCTest
@testable import UpNext

private final class BaselinePublicationTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    init(_ remaining: Int) { self.remaining = remaining }
    func shouldContinue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

final class StoreSplitBaselinePublicationTests: XCTestCase {
    private struct Stores {
        let legacy: ModelContainer
        let userState: ModelContainer
        let cache: ModelContainer
    }

    @MainActor
    private func makeStores() throws -> Stores {
        Stores(
            legacy: try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true),
            userState: try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true),
            cache: try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        )
    }

    @MainActor
    private func completePhasesBefore(_ target: String, cache: ModelContainer) throws {
        let context = ModelContext(cache)
        for phase in StoreSplitMigrationService.slicePhaseOrder {
            if phase == target { break }
            context.insert(StoreSplitMigrationCheckpoint(
                id: StoreSplitMigrationService.checkpointID(for: phase),
                migrationVersion: StoreSplitMigrationService.migrationVersion,
                phase: phase,
                cursor: "0",
                completedAt: .now
            ))
        }
        try context.save()
    }

    @MainActor
    private func insertAggregate(feed: String, seconds: Double, in context: ModelContext) {
        let namespace = "listening-baseline-\(StoreSplitMigrationService.checkpointID(for: StoreSplitMigrationService.Phase.listeningSummaries))"
        let row = CachedListeningBaselineAggregate(id: StableIdentityKey.make(namespace, feed), feedURL: feed, podcastName: "Example")
        row.totalSeconds = seconds
        row.silenceGapTimeSavedSeconds = seconds / 10
        row.playbackRateTimeSavedSeconds = seconds / 5
        context.insert(row)
    }

    @MainActor
    private func runUntilPhaseChanges(_ phase: String, stores: Stores) async -> [StoreSplitSliceReport] {
        var reports: [StoreSplitSliceReport] = []
        for _ in 0..<300 {
            let report = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
            reports.append(report)
            if report.phase != phase || report.status != .advanced { break }
        }
        return reports
    }

    @MainActor
    func testLargePublicationUsesBoundedPagesAndPreservesExistingBaseline() async throws {
        let stores = try makeStores()
        try completePhasesBefore(StoreSplitMigrationService.Phase.listeningBaselinePublication, cache: stores.cache)
        let cache = ModelContext(stores.cache)
        for index in 0..<125 { insertAggregate(feed: "https://example.com/\(index).xml", seconds: Double(index + 1), in: cache) }
        try cache.save()
        let existing = ListeningBaselineSync(feedURL: "https://example.com/1.xml", totalSeconds: 999, capturedByDeviceID: "other-device")
        stores.userState.mainContext.insert(existing)
        for index in 0..<125 where index != 1 {
            stores.userState.mainContext.insert(ListeningBaselineSync(feedURL: "https://example.com/\(index).xml", totalSeconds: Double(index + 1), capturedByDeviceID: "other-device"))
        }
        try stores.userState.mainContext.save()

        let reports = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselinePublication, stores: stores)
        XCTAssertEqual(reports.last?.status, .phaseCompleted)
        XCTAssertEqual(reports.reduce(0) { $0 + $1.processed }, 125)
        XCTAssertTrue(reports.allSatisfy { $0.processed <= 40 && $0.mutations == 0 && $0.saveCount <= 1 })
        let baselines = try ModelContext(stores.userState).fetch(FetchDescriptor<ListeningBaselineSync>())
        XCTAssertEqual(baselines.count, 125)
        XCTAssertEqual(baselines.first { $0.feedURL == existing.feedURL }?.totalSeconds, 999)
        XCTAssertEqual(baselines.first { $0.feedURL == existing.feedURL }?.capturedByDeviceID, "other-device")
        XCTAssertEqual(try ModelContext(stores.cache).fetchCount(FetchDescriptor<CachedListeningBaselineAggregate>()), 125)
    }

    @MainActor
    func testCancellationBeforeCheckpointRetriesWithoutChangingBaseline() async throws {
        let stores = try makeStores()
        try completePhasesBefore(StoreSplitMigrationService.Phase.listeningBaselinePublication, cache: stores.cache)
        let cache = ModelContext(stores.cache)
        insertAggregate(feed: "https://example.com/retry.xml", seconds: 120, in: cache)
        try cache.save()
        stores.userState.mainContext.insert(ListeningBaselineSync(feedURL: "https://example.com/retry.xml", totalSeconds: 120, capturedByDeviceID: "other-device"))
        try stores.userState.mainContext.save()
        let gate = BaselinePublicationTestGate(4)
        let cancelled = await StoreSplitMigrationService.runSlice(
            legacyContainer: stores.legacy, userStateContainer: stores.userState,
            cacheContainer: stores.cache, shouldContinue: { gate.shouldContinue() }
        )
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(try ModelContext(stores.userState).fetchCount(FetchDescriptor<ListeningBaselineSync>()), 1)
        XCTAssertEqual(try ModelContext(stores.cache).fetchCount(FetchDescriptor<CachedListeningBaselineAggregate>()), 1)
        let retried = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
        XCTAssertEqual(retried.status, .phaseCompleted)
        XCTAssertEqual(try ModelContext(stores.userState).fetchCount(FetchDescriptor<ListeningBaselineSync>()), 1)
        XCTAssertEqual(try ModelContext(stores.cache).fetchCount(FetchDescriptor<CachedListeningBaselineAggregate>()), 1)
    }

    @MainActor
    func testMissingBaselineBlocksWithoutPublishingAndRetriesAfterImport() async throws {
        let stores = try makeStores()
        try completePhasesBefore(StoreSplitMigrationService.Phase.listeningBaselinePublication, cache: stores.cache)
        let cache = ModelContext(stores.cache)
        insertAggregate(feed: "https://example.com/save-failure.xml", seconds: 100, in: cache)
        try cache.save()
        let failed = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.error, "baseline_publication_source_evidence_unresolved")
        XCTAssertEqual(try ModelContext(stores.cache).fetchCount(FetchDescriptor<CachedListeningBaselineAggregate>()), 1)
        XCTAssertEqual(try ModelContext(stores.userState).fetchCount(FetchDescriptor<ListeningBaselineSync>()), 0)
        stores.userState.mainContext.insert(ListeningBaselineSync(feedURL: "https://example.com/save-failure.xml", totalSeconds: 100, capturedByDeviceID: "other-device"))
        try stores.userState.mainContext.save()
        let retried = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
        XCTAssertEqual(retried.status, .phaseCompleted)
        XCTAssertEqual(try ModelContext(stores.userState).fetchCount(FetchDescriptor<ListeningBaselineSync>()), 1)
    }

    @MainActor
    func testCacheCommitFailureRetriesWithoutChangingExistingBaseline() async throws {
        let original = try makeStores()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cache.sqlite")
        let cache = try ModelContainerManager.makeCacheContainer(storageURL: url)
        try completePhasesBefore(StoreSplitMigrationService.Phase.listeningBaselinePublication, cache: cache)
        let context = ModelContext(cache)
        insertAggregate(feed: "https://example.com/cache-failure.xml", seconds: 100, in: context)
        try context.save()
        original.userState.mainContext.insert(ListeningBaselineSync(feedURL: "https://example.com/cache-failure.xml", totalSeconds: 100, capturedByDeviceID: "other-device"))
        try original.userState.mainContext.save()
        let schema = cache.schema
        let readOnly = try ModelContainer(for: schema, configurations: ModelConfiguration("PodcastCache", schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none))

        let failed = await StoreSplitMigrationService.runSlice(legacyContainer: original.legacy, userStateContainer: original.userState, cacheContainer: readOnly)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.error, "checkpoint_save_failed")
        XCTAssertEqual(try ModelContext(original.userState).fetchCount(FetchDescriptor<ListeningBaselineSync>()), 1)
        XCTAssertEqual(try ModelContext(cache).fetchCount(FetchDescriptor<CachedListeningBaselineAggregate>()), 1)

        let retried = await StoreSplitMigrationService.runSlice(legacyContainer: original.legacy, userStateContainer: original.userState, cacheContainer: cache)
        XCTAssertEqual(retried.status, .phaseCompleted)
        XCTAssertEqual(try ModelContext(original.userState).fetchCount(FetchDescriptor<ListeningBaselineSync>()), 1)
        XCTAssertEqual(try ModelContext(cache).fetchCount(FetchDescriptor<CachedListeningBaselineAggregate>()), 1)
    }

    @MainActor
    func testLegacyDuplicateReceiptsRemainPreservedAndBlockMigration() async throws {
        let stores = try makeStores()
        try completePhasesBefore(StoreSplitMigrationService.Phase.listeningBaselinePrepareSources, cache: stores.cache)
        let context = ModelContext(stores.cache)
        let duplicateID = StableIdentityKey.make("listening-baseline-source", "duplicate")
        for _ in 0..<45 { context.insert(CachedListeningBaselineSource(id: duplicateID)) }
        try context.save()
        let reports = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselinePrepareSources, stores: stores)
        XCTAssertEqual(reports.last?.status, .failed)
        XCTAssertEqual(reports.last?.error, "baseline_legacy_partial_scratch_unresolved")
        XCTAssertEqual(try ModelContext(stores.cache).fetchCount(FetchDescriptor<CachedListeningBaselineSource>()), 45)
    }

    @MainActor
    func testUpgradeBlocksAndPreservesOldPartialScratch() async throws {
        let stores = try makeStores()
        try completePhasesBefore(StoreSplitMigrationService.Phase.listeningBaselinePrepareAggregates, cache: stores.cache)
        let cache = ModelContext(stores.cache)
        let feed = "https://example.com/upgrade.xml"
        let oldAggregate = CachedListeningBaselineAggregate(id: StableIdentityKey.make("listening-baseline", feed), feedURL: feed, podcastName: "Old")
        oldAggregate.totalSeconds = 9_999
        cache.insert(oldAggregate)
        cache.insert(CachedListeningBaselineSource(id: StableIdentityKey.make("listening-baseline-source", "old-row")))
        cache.insert(StoreSplitMigrationCheckpoint(id: "v8.listening_summaries.r1", migrationVersion: 8, phase: "listening_summaries", cursor: "1", completedAt: .now))
        try cache.save()
        stores.legacy.mainContext.insert(PlaySessionSummary(id: UUID(), periodKind: PlaySessionSummaryPeriod.year.rawValue, periodStart: .now, podcastFeed: URL(string: feed), totalSeconds: 100))
        stores.userState.mainContext.insert(ListeningBaselineSync(feedURL: feed, totalSeconds: 150, capturedByDeviceID: "other-device"))
        try stores.legacy.mainContext.save()
        try stores.userState.mainContext.save()

        let reports = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselinePrepareAggregates, stores: stores)
        XCTAssertEqual(reports.last?.status, .failed)
        XCTAssertEqual(reports.last?.error, "baseline_legacy_partial_scratch_unresolved")
        let baseline = try XCTUnwrap(ModelContext(stores.userState).fetch(FetchDescriptor<ListeningBaselineSync>()).first)
        XCTAssertEqual(baseline.totalSeconds, 150)
        XCTAssertEqual(baseline.capturedByDeviceID, "other-device")
        XCTAssertEqual(try ModelContext(stores.cache).fetch(FetchDescriptor<CachedListeningBaselineAggregate>()).first?.totalSeconds, 9_999)
        XCTAssertEqual(try ModelContext(stores.cache).fetchCount(FetchDescriptor<CachedListeningBaselineSource>()), 1)
    }

    @MainActor
    func testCompletedOldCheckpointRescansIntoVersionedScratchAndPreservesBaseline() async throws {
        let stores = try makeStores()
        try completePhasesBefore(StoreSplitMigrationService.Phase.listeningBaselinePrepareAggregates, cache: stores.cache)
        let cache = ModelContext(stores.cache)
        cache.insert(StoreSplitMigrationCheckpoint(id: "v8.listening_summaries.r1", migrationVersion: 8, phase: "listening_summaries", cursor: "1", completedAt: .now))
        try cache.save()
        let feed = "https://example.com/upgrade-complete.xml"
        stores.legacy.mainContext.insert(PlaySessionSummary(id: UUID(), periodKind: PlaySessionSummaryPeriod.year.rawValue, periodStart: .now, podcastFeed: URL(string: feed), totalSeconds: 100))
        stores.userState.mainContext.insert(ListeningBaselineSync(feedURL: feed, totalSeconds: 150, capturedByDeviceID: "other-device"))
        try stores.legacy.mainContext.save()
        try stores.userState.mainContext.save()
        for phase in [StoreSplitMigrationService.Phase.listeningBaselinePrepareAggregates, StoreSplitMigrationService.Phase.listeningBaselinePrepareSources, StoreSplitMigrationService.Phase.listeningSummaries, StoreSplitMigrationService.Phase.listeningBaselinePublication] {
            let reports = await runUntilPhaseChanges(phase, stores: stores)
            XCTAssertEqual(reports.last?.status, .phaseCompleted, phase)
        }
        let baseline = try XCTUnwrap(ModelContext(stores.userState).fetch(FetchDescriptor<ListeningBaselineSync>()).first)
        XCTAssertEqual(baseline.totalSeconds, 150)
        XCTAssertEqual(baseline.capturedByDeviceID, "other-device")
        XCTAssertEqual(try ModelContext(stores.cache).fetchCount(FetchDescriptor<CachedListeningBaselineAggregate>()), 1)
        XCTAssertEqual(try ModelContext(stores.cache).fetchCount(FetchDescriptor<CachedListeningBaselineSource>()), 1)
    }

    @MainActor
    func testOrphanedVersionedScratchBlocksWithoutDeletion() async throws {
        let stores = try makeStores()
        try completePhasesBefore(StoreSplitMigrationService.Phase.listeningSummaries, cache: stores.cache)
        let context = ModelContext(stores.cache)
        insertAggregate(feed: "https://example.com/orphan.xml", seconds: 123, in: context)
        try context.save()
        let report = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.error, "baseline_scan_orphaned_scratch_unresolved")
        XCTAssertEqual(try ModelContext(stores.cache).fetch(FetchDescriptor<CachedListeningBaselineAggregate>()).first?.totalSeconds, 123)
    }

    @MainActor
    func testUnresolvedBaselineDoesNotPreventHistoryAndEpisodeBackfill() async throws {
        let defaults = UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
        let key = "storeSplit.verificationAttemptInvalidated.v1"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let stores = try makeStores()
        let feed = URL(string: "https://example.com/independent-backfill.xml")!
        let podcast = Podcast(feed: feed)
        podcast.title = "Example"
        let episode = Episode(guid: "independent-episode", title: "Episode", url: URL(string: "https://example.com/audio.mp3")!, podcast: podcast, duration: 120)
        episode.metaData?.playPosition = 45
        episode.metaData?.maxPlayposition = 45
        episode.metaData?.lastPlayed = Date(timeIntervalSince1970: 1_700_000_000)
        podcast.episodes = [episode]
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = PlaySession(id: UUID(), episode: episode, sourceDeviceID: "fixture-device", startTime: start, endTime: start.addingTimeInterval(120), startPosition: 0, endPosition: 120, endedCleanly: true)
        stores.legacy.mainContext.insert(podcast)
        stores.legacy.mainContext.insert(episode)
        stores.legacy.mainContext.insert(session)
        stores.legacy.mainContext.insert(PlaySessionSummary(id: UUID(), periodKind: PlaySessionSummaryPeriod.year.rawValue, periodStart: start, podcastFeed: feed, totalSeconds: 120))
        try stores.legacy.mainContext.save()

        var last: StoreSplitSliceReport?
        for _ in 0..<100 {
            let report = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
            last = report
            if report.status == .failed || report.status == .completed || report.status == .cancelled { break }
        }
        XCTAssertEqual(last?.phase, StoreSplitMigrationService.Phase.listeningBaselinePublication)
        XCTAssertEqual(last?.status, .failed)
        XCTAssertEqual(last?.error, "baseline_publication_source_evidence_unresolved")
        XCTAssertEqual(try ModelContext(stores.userState).fetchCount(FetchDescriptor<ListeningHistorySync>()), 1)
        XCTAssertEqual(try ModelContext(stores.userState).fetchCount(FetchDescriptor<EpisodeStateSync>()), 1)
        XCTAssertEqual(try ModelContext(stores.userState).fetchCount(FetchDescriptor<ListeningBaselineSync>()), 0)
        for phase in [StoreSplitMigrationService.Phase.listeningHistory, StoreSplitMigrationService.Phase.episodeStates, StoreSplitMigrationService.Phase.aiTranscripts, StoreSplitMigrationService.Phase.aiChapters, StoreSplitMigrationService.Phase.listeningHistoryVerification] {
            let id = StoreSplitMigrationService.checkpointID(for: phase)
            let checkpoint = try XCTUnwrap(ModelContext(stores.cache).fetch(FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == id })).first)
            XCTAssertNotNil(checkpoint.completedAt, phase)
        }
    }
}
