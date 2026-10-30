import SwiftData
import XCTest
@testable import UpNext

private final class BaselineVerificationTestGate: @unchecked Sendable {
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

final class StoreSplitIncrementalBaselineVerificationTests: XCTestCase {
    private let invalidationKey = "storeSplit.verificationAttemptInvalidated.v1"

    private func preserveInvalidationDefault() -> () -> Void {
        let defaults = UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
        let previous = defaults.object(forKey: invalidationKey)
        let key = invalidationKey
        return {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
    private struct Stores {
        let legacy: ModelContainer
        let userState: ModelContainer
        let cache: ModelContainer
    }

    @MainActor
    private func makeStores(cache: ModelContainer? = nil) throws -> Stores {
        let stores = Stores(
            legacy: try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true),
            userState: try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true),
            cache: try cache ?? ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(stores.cache)
        for phase in StoreSplitMigrationService.slicePhaseOrder
        where phase != StoreSplitMigrationService.Phase.listeningBaselineVerificationScan
            && phase != StoreSplitMigrationService.Phase.listeningBaselineVerification
            && phase != StoreSplitMigrationService.Phase.listeningBaselineVerificationComparison {
            context.insert(StoreSplitMigrationCheckpoint(
                id: StoreSplitMigrationService.checkpointID(for: phase),
                migrationVersion: StoreSplitMigrationService.migrationVersion,
                phase: phase,
                cursor: "0",
                startedAt: .now,
                completedAt: .now
            ))
        }
        try context.save()
        return stores
    }

    private func summaryID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!
    }

    @MainActor
    private func insertSummary(_ index: Int, feed: String, in context: ModelContext) {
        context.insert(PlaySessionSummary(
            id: summaryID(index),
            periodKind: PlaySessionSummaryPeriod.year.rawValue,
            periodStart: Date(timeIntervalSince1970: Double(index) * 1000),
            podcastFeed: URL(string: feed),
            podcastName: "Example",
            totalSeconds: 100,
            silenceGapTimeSavedSeconds: 5,
            playbackRateTimeSavedSeconds: 10
        ))
    }

    @MainActor
    private func insertBaseline(feed: String, count: Int, device: String? = ListeningDeviceIdentity.current().id, in context: ModelContext) {
        context.insert(ListeningBaselineSync(
            feedURL: feed,
            totalSeconds: Double(count * 100),
            silenceGapTimeSavedSeconds: Double(count * 5),
            playbackRateTimeSavedSeconds: Double(count * 10),
            capturedByDeviceID: device
        ))
    }

    @MainActor
    private func runUntilPhaseChanges(_ phase: String, stores: Stores) async -> [StoreSplitSliceReport] {
        var reports: [StoreSplitSliceReport] = []
        for _ in 0..<30 {
            let report = await StoreSplitMigrationService.runSlice(
                legacyContainer: stores.legacy,
                userStateContainer: stores.userState,
                cacheContainer: stores.cache
            )
            reports.append(report)
            if report.phase != phase || report.status != .advanced { break }
        }
        return reports
    }

    @MainActor
    func testIndependentPassesVerifyPerFeedTotalsAcrossPages() async throws {
        let restoreDefaults = preserveInvalidationDefault()
        defer { restoreDefaults() }
        let stores = try makeStores()
        let feeds = ["https://example.com/a.xml", "https://example.com/b.xml", "https://example.com/c.xml"]
        for index in 0..<111 { insertSummary(index, feed: feeds[index % feeds.count], in: stores.legacy.mainContext) }
        for feed in feeds { insertBaseline(feed: feed, count: 37, in: stores.userState.mainContext) }
        try stores.legacy.mainContext.save()
        try stores.userState.mainContext.save()

        let scan = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerificationScan, stores: stores)
        XCTAssertEqual(scan.last?.status, .phaseCompleted)
        XCTAssertEqual(scan.reduce(0) { $0 + $1.processed }, 111)
        XCTAssertTrue(scan.allSatisfy { $0.processed <= 40 })

        let comparison = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerification, stores: stores)
        XCTAssertEqual(comparison.last?.status, .phaseCompleted)
        XCTAssertEqual(comparison.reduce(0) { $0 + $1.processed }, 111)
        XCTAssertTrue(comparison.allSatisfy { $0.processed <= 40 })
        let feedsCompared = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerificationComparison, stores: stores)
        XCTAssertEqual(feedsCompared.last?.status, .completed)
        XCTAssertEqual(feedsCompared.reduce(0) { $0 + $1.processed }, feeds.count)
        XCTAssertFalse(StoreSplitMigrationService.isMigrationVerified(cacheContainer: stores.cache))
    }

    @MainActor
    func testChangedSourceFailsComparisonAndRetainsCursor() async throws {
        let restoreDefaults = preserveInvalidationDefault()
        defer { restoreDefaults() }
        let stores = try makeStores()
        let feed = "https://example.com/a.xml"
        insertSummary(0, feed: feed, in: stores.legacy.mainContext)
        insertBaseline(feed: feed, count: 1, in: stores.userState.mainContext)
        try stores.legacy.mainContext.save()
        try stores.userState.mainContext.save()
        let scan = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerificationScan, stores: stores)
        XCTAssertEqual(scan.last?.status, .phaseCompleted)

        let summary = try XCTUnwrap(stores.legacy.mainContext.fetch(FetchDescriptor<PlaySessionSummary>()).first)
        summary.totalSeconds = 101
        try stores.legacy.mainContext.save()
        let report = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.error, "baseline_verification_source_changed")
        let id = StoreSplitMigrationService.checkpointID(for: StoreSplitMigrationService.Phase.listeningBaselineVerification)
        let checkpoint = try XCTUnwrap(ModelContext(stores.cache).fetch(FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == id })).first)
        XCTAssertNil(checkpoint.completedAt)
        XCTAssertEqual(checkpoint.scannedCount, 0)
        XCTAssertEqual(checkpoint.failedCount, 1)
    }

    @MainActor
    func testOtherDeviceBaselineIsAcceptedUnchanged() async throws {
        let restoreDefaults = preserveInvalidationDefault()
        defer { restoreDefaults() }
        let stores = try makeStores()
        let feed = "https://example.com/a.xml"
        insertSummary(0, feed: feed, in: stores.legacy.mainContext)
        insertBaseline(feed: feed, count: 1, device: "other-device", in: stores.userState.mainContext)
        try stores.legacy.mainContext.save()
        try stores.userState.mainContext.save()
        let scan = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerificationScan, stores: stores)
        XCTAssertEqual(scan.last?.status, .phaseCompleted)
        let second = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerification, stores: stores)
        XCTAssertEqual(second.last?.status, .phaseCompleted)
        let report = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
        XCTAssertNotEqual(report.status, .failed)
        let persisted = try XCTUnwrap(ModelContext(stores.userState).fetch(FetchDescriptor<ListeningBaselineSync>()).first)
        XCTAssertEqual(persisted.capturedByDeviceID, "other-device")
        XCTAssertEqual(persisted.totalSeconds, 100)
    }

    @MainActor
    func testMissingSourceIdentityFailsClosed() async throws {
        let restoreDefaults = preserveInvalidationDefault()
        defer { restoreDefaults() }
        let stores = try makeStores()
        stores.legacy.mainContext.insert(PlaySessionSummary(id: nil, periodKind: PlaySessionSummaryPeriod.year.rawValue, periodStart: .now, totalSeconds: 100))
        try stores.legacy.mainContext.save()
        let report = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.error, "baseline_verification_source_identity_unresolved")
        XCTAssertEqual(report.processed, 0)
    }

    @MainActor
    func testDuplicateVerificationLedgerRowsFailClosed() async throws {
        let restoreDefaults = preserveInvalidationDefault()
        defer { restoreDefaults() }
        for duplicate in ["marker", "aggregate", "receipt"] {
            let stores = try makeStores()
            let feed = "https://example.com/a.xml"
            insertSummary(0, feed: feed, in: stores.legacy.mainContext)
            insertBaseline(feed: feed, count: 1, in: stores.userState.mainContext)
            try stores.legacy.mainContext.save()
            try stores.userState.mainContext.save()
            let scan = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerificationScan, stores: stores)
            XCTAssertEqual(scan.last?.status, .phaseCompleted)
            let context = ModelContext(stores.cache)
            if duplicate == "receipt" {
                let receipt = try XCTUnwrap(context.fetch(FetchDescriptor<CachedListeningBaselineSource>()).first)
                context.insert(CachedListeningBaselineSource(id: receipt.id))
            } else {
                let aggregates = try context.fetch(FetchDescriptor<CachedListeningBaselineAggregate>())
                let original = try XCTUnwrap(aggregates.first { duplicate == "marker" ? $0.feedURL == "year" : $0.feedURL == feed })
                context.insert(CachedListeningBaselineAggregate(id: original.id, feedURL: original.feedURL, podcastName: original.podcastName))
            }
            try context.save()
            var result = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
            if duplicate == "aggregate" && result.status == .phaseCompleted {
                result = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
            }
            XCTAssertEqual(result.status, .failed, duplicate)
            XCTAssertEqual(result.error, "baseline_verification_cache_read_failed", duplicate)
            XCTAssertEqual(result.processed, 0, duplicate)
        }
    }

    @MainActor
    func testTierChangeBeforeScanCompletionFailsWithoutAdvancingLastPage() async throws {
        let restoreDefaults = preserveInvalidationDefault()
        defer { restoreDefaults() }
        let stores = try makeStores()
        let feed = "https://example.com/a.xml"
        for index in 0..<41 {
            let summary = PlaySessionSummary(id: summaryID(index), periodKind: PlaySessionSummaryPeriod.month.rawValue, periodStart: Date(timeIntervalSince1970: Double(index) * 1000), podcastFeed: URL(string: feed), totalSeconds: 100)
            stores.legacy.mainContext.insert(summary)
        }
        try stores.legacy.mainContext.save()
        let first = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
        XCTAssertEqual(first.status, .advanced)
        XCTAssertEqual(first.processed, 40)
        insertSummary(99, feed: feed, in: stores.legacy.mainContext)
        try stores.legacy.mainContext.save()
        let second = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
        XCTAssertEqual(second.status, .failed)
        XCTAssertEqual(second.error, "baseline_verification_source_tier_changed")
        let id = StoreSplitMigrationService.checkpointID(for: StoreSplitMigrationService.Phase.listeningBaselineVerificationScan)
        let checkpoint = try XCTUnwrap(ModelContext(stores.cache).fetch(FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == id })).first)
        XCTAssertEqual(checkpoint.scannedCount, 40)
        XCTAssertNil(checkpoint.completedAt)
    }

    @MainActor
    func testCorruptedFirstAggregateIsDetectedByIndependentPass() async throws {
        let restoreDefaults = preserveInvalidationDefault()
        defer { restoreDefaults() }
        let stores = try makeStores()
        let feed = "https://example.com/a.xml"
        insertSummary(0, feed: feed, in: stores.legacy.mainContext)
        insertBaseline(feed: feed, count: 1, in: stores.userState.mainContext)
        try stores.legacy.mainContext.save()
        try stores.userState.mainContext.save()
        let first = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerificationScan, stores: stores)
        XCTAssertEqual(first.last?.status, .phaseCompleted)
        let second = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerification, stores: stores)
        XCTAssertEqual(second.last?.status, .phaseCompleted)
        let context = ModelContext(stores.cache)
        let aggregate = try XCTUnwrap(context.fetch(FetchDescriptor<CachedListeningBaselineAggregate>()).first {
            StableIdentityKey.components(from: $0.id)?.first == "baseline-verification-aggregate"
        })
        aggregate.totalSeconds += 1
        try context.save()
        let result = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.error, "baseline_verification_aggregate_mismatch")
        XCTAssertEqual(result.processed, 0)
    }

    @MainActor
    func testCacheReopenResumesAtCommittedPageWithoutDoubleCounting() async throws {
        let restoreDefaults = preserveInvalidationDefault()
        defer { restoreDefaults() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("cache.sqlite")
        let stores = try makeStores(cache: ModelContainerManager.makeCacheContainer(storageURL: cacheURL))
        let feed = "https://example.com/a.xml"
        for index in 0..<81 { insertSummary(index, feed: feed, in: stores.legacy.mainContext) }
        insertBaseline(feed: feed, count: 81, in: stores.userState.mainContext)
        try stores.legacy.mainContext.save()
        try stores.userState.mainContext.save()
        let first = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
        XCTAssertEqual(first.status, .advanced)
        XCTAssertEqual(first.processed, 40)

        let reopened = Stores(legacy: stores.legacy, userState: stores.userState, cache: try ModelContainerManager.makeCacheContainer(storageURL: cacheURL))
        let rest = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerificationScan, stores: reopened)
        XCTAssertEqual(rest.last?.status, .phaseCompleted)
        XCTAssertEqual(first.processed + rest.reduce(0) { $0 + $1.processed }, 81)
        let second = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerification, stores: reopened)
        XCTAssertEqual(second.last?.status, .phaseCompleted)
        let comparison = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerificationComparison, stores: reopened)
        XCTAssertEqual(comparison.last?.status, .completed)
    }

    @MainActor
    func testCancellationRollsBackUncommittedPageAndRetryDoesNotDoubleCount() async throws {
        let restoreDefaults = preserveInvalidationDefault()
        defer { restoreDefaults() }
        let stores = try makeStores()
        let feed = "https://example.com/a.xml"
        for index in 0..<3 { insertSummary(index, feed: feed, in: stores.legacy.mainContext) }
        insertBaseline(feed: feed, count: 3, in: stores.userState.mainContext)
        try stores.legacy.mainContext.save()
        try stores.userState.mainContext.save()
        let gate = BaselineVerificationTestGate(3)
        let cancelled = await StoreSplitMigrationService.runSlice(
            legacyContainer: stores.legacy,
            userStateContainer: stores.userState,
            cacheContainer: stores.cache,
            shouldContinue: { gate.shouldContinue() }
        )
        XCTAssertEqual(cancelled.status, .cancelled)
        let checkpointID = StoreSplitMigrationService.checkpointID(for: StoreSplitMigrationService.Phase.listeningBaselineVerificationScan)
        XCTAssertTrue(try ModelContext(stores.cache).fetch(FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == checkpointID })).isEmpty)
        XCTAssertTrue(try ModelContext(stores.cache).fetch(FetchDescriptor<CachedListeningBaselineSource>()).isEmpty)
        let scan = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerificationScan, stores: stores)
        XCTAssertEqual(scan.last?.status, .phaseCompleted)
        let second = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerification, stores: stores)
        XCTAssertEqual(second.last?.status, .phaseCompleted)
        let comparison = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerificationComparison, stores: stores)
        XCTAssertEqual(comparison.last?.status, .completed)
    }

    @MainActor
    func testDuplicateCompletedCheckpointsDoNotAppearComplete() async throws {
        let restoreDefaults = preserveInvalidationDefault()
        defer { restoreDefaults() }
        let stores = try makeStores()
        let context = ModelContext(stores.cache)
        let phase = StoreSplitMigrationService.Phase.listeningBaselineVerificationScan
        let id = StoreSplitMigrationService.checkpointID(for: phase)
        for _ in 0..<2 {
            context.insert(StoreSplitMigrationCheckpoint(id: id, migrationVersion: StoreSplitMigrationService.migrationVersion, phase: phase, completedAt: .now))
        }
        try context.save()
        XCTAssertFalse(StoreSplitMigrationService.isSliceMigrationComplete(cacheContainer: stores.cache))
        let result = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.error, "baseline_verification_checkpoint_invalid")
    }

    @MainActor
    func testDeletingBothAggregatesCannotProduceAnEmptySuccessfulComparison() async throws {
        let restoreDefaults = preserveInvalidationDefault()
        defer { restoreDefaults() }
        let stores = try makeStores()
        let feed = "https://example.com/a.xml"
        insertSummary(0, feed: feed, in: stores.legacy.mainContext)
        insertBaseline(feed: feed, count: 1, in: stores.userState.mainContext)
        try stores.legacy.mainContext.save()
        try stores.userState.mainContext.save()
        let scan = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerificationScan, stores: stores)
        XCTAssertEqual(scan.last?.status, .phaseCompleted)
        let second = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerification, stores: stores)
        XCTAssertEqual(second.last?.status, .phaseCompleted)
        let context = ModelContext(stores.cache)
        for aggregate in try context.fetch(FetchDescriptor<CachedListeningBaselineAggregate>()) where aggregate.feedURL == feed {
            context.delete(aggregate)
        }
        for receipt in try context.fetch(FetchDescriptor<CachedListeningBaselineSource>())
        where StableIdentityKey.components(from: receipt.id)?.first == "baseline-verification-recheck-feed" {
            context.delete(receipt)
        }
        try context.save()
        let report = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.error, "baseline_verification_aggregate_mismatch")
    }

    @MainActor
    func testResetScanCheckpointCannotReuseLaterCompletedRuns() async throws {
        let restoreDefaults = preserveInvalidationDefault()
        defer { restoreDefaults() }
        let stores = try makeStores()
        let feed = "https://example.com/a.xml"
        insertSummary(0, feed: feed, in: stores.legacy.mainContext)
        insertBaseline(feed: feed, count: 1, in: stores.userState.mainContext)
        try stores.legacy.mainContext.save()
        try stores.userState.mainContext.save()
        _ = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerificationScan, stores: stores)
        _ = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerification, stores: stores)
        let original = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerificationComparison, stores: stores)
        XCTAssertEqual(original.last?.status, .completed)
        let id = StoreSplitMigrationService.checkpointID(for: StoreSplitMigrationService.Phase.listeningBaselineVerificationScan)
        let context = ModelContext(stores.cache)
        let checkpoint = try XCTUnwrap(context.fetch(FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == id })).first)
        context.delete(checkpoint)
        try context.save()

        let rescan = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerificationScan, stores: stores)
        XCTAssertEqual(rescan.last?.status, .phaseCompleted)
        XCTAssertFalse(StoreSplitMigrationService.isSliceMigrationComplete(cacheContainer: stores.cache))
        let second = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerification, stores: stores)
        XCTAssertEqual(second.last?.status, .phaseCompleted)
        XCTAssertEqual(second.reduce(0) { $0 + $1.processed }, 1)
        XCTAssertFalse(StoreSplitMigrationService.isSliceMigrationComplete(cacheContainer: stores.cache))
        let comparison = await runUntilPhaseChanges(StoreSplitMigrationService.Phase.listeningBaselineVerificationComparison, stores: stores)
        XCTAssertEqual(comparison.last?.status, .completed)
        XCTAssertEqual(comparison.reduce(0) { $0 + $1.processed }, 1)
    }
}
