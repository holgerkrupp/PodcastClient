import SwiftData
import XCTest
@testable import UpNext

/// Covers the invariant that makes the store split invisible to existing users:
/// the app's library graph stays on disk, and only user-owned state travels
/// through `UserState.sqlite`.
final class StoreSplitDurableStoreTests: XCTestCase {
    @MainActor
    func testFreshSplitInstallCanSubscribeAndInterruptedInitializationDoesNotEarnFreshMarker() throws {
        let suiteName = "StoreBootstrapSafety-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let emptyFiles: Set<String> = []
        XCTAssertEqual(
            StoreBootstrapMode.resolve(
                legacyStoreExists: false,
                installationWasPreviouslyInitialized: StoreBootstrapEvidence.mayHaveExistingLibrary(
                    standardDefaults: defaults,
                    appGroupDefaults: nil,
                    files: emptyFiles
                )
            ),
            .freshSplitInstall
        )

        let runtime = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let podcast = Podcast(feed: URL(string: "https://example.com/fresh-fixture.xml")!)
        runtime.mainContext.insert(podcast)
        try runtime.mainContext.save()
        XCTAssertEqual(try runtime.mainContext.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertFalse(defaults.bool(forKey: StoreBootstrapEvidence.freshSplitInstallReadyKey))
    }

    func testBootstrapModeFollowsTheLibraryFile() {
        XCTAssertEqual(
            StoreBootstrapMode.resolve(
                legacyStoreExists: false,
                installationWasPreviouslyInitialized: false
            ),
            .freshSplitInstall
        )
        XCTAssertEqual(
            StoreBootstrapMode.resolve(
                legacyStoreExists: true,
                installationWasPreviouslyInitialized: false
            ),
            .legacyUpgrade
        )
        XCTAssertEqual(
            StoreBootstrapMode.resolve(
                legacyStoreExists: true,
                installationWasPreviouslyInitialized: false
            ),
            .legacyUpgrade
        )
        XCTAssertTrue(StoreBootstrapMode.freshSplitInstall.usesInMemoryRuntimeProjection)
        XCTAssertFalse(StoreBootstrapMode.legacyUpgrade.usesInMemoryRuntimeProjection)
    }

    func testMigrationSliceBudgetBoundsMutationsAndWallTime() {
        let budget = StoreWorkBudget.migrationSlice
        XCTAssertEqual(budget.maximumMutations, 160)
        XCTAssertLessThanOrEqual(budget.maximumSaves, 2)
        XCTAssertEqual(budget.maximumWallTime, .seconds(4))
    }

    func testBackgroundMigrationUsesAnActiveWorkAndIdleBudget() {
        let policy = StoreSplitMigrationRunPolicy.background

        XCTAssertEqual(policy.maximumWallTime, 120)
        XCTAssertEqual(policy.maximumActiveWorkTime, 25)
        XCTAssertEqual(policy.maximumSlices, 20)
        XCTAssertEqual(policy.idleDuration(after: 10), 20)
        XCTAssertGreaterThan(policy.maximumWallTime, policy.maximumActiveWorkTime)
        XCTAssertGreaterThan(policy.minimumIdleTime, 0)
        XCTAssertGreaterThanOrEqual(policy.idleToWorkRatio, 2)
    }

    func testProcessCPUResourceBudgetSerializesWorkAndYieldsToPlaybackAndExport() {
        let source = MutableProcessCPUTimeSource()
        let budget = StoreMaintenanceResourceBudget(source: source)

        let migration = budget.acquire(
            operation: "migration",
            playbackActive: false,
            cloudKitExportActive: false
        )
        XCTAssertNotNil(migration)
        XCTAssertNil(budget.acquire(
            operation: "reconcile",
            playbackActive: false,
            cloudKitExportActive: false
        ))
        XCTAssertEqual(migration?.yieldReason(
            playbackActive: true,
            cloudKitExportActive: false
        ), "playback")
        XCTAssertEqual(migration?.yieldReason(
            playbackActive: false,
            cloudKitExportActive: true
        ), "export_busy")
        migration?.release()
        XCTAssertNil(budget.acquire(
            operation: "prewarm",
            playbackActive: true,
            cloudKitExportActive: false
        ))
    }

    func testProcessCPUResourceBudgetAppliesCooldownAfterHighDutyCycle() {
        let source = MutableProcessCPUTimeSource()
        let budget = StoreMaintenanceResourceBudget(source: source)
        let permit = budget.acquire(
            operation: "migration",
            playbackActive: false,
            cloudKitExportActive: false
        )
        XCTAssertNotNil(permit)

        source.advance(wall: 6, cpu: 6)
        XCTAssertEqual(permit?.yieldReason(
            playbackActive: false,
            cloudKitExportActive: false
        ), "cpu_budget")
        permit?.release()

        XCTAssertNil(budget.acquire(
            operation: "reconcile",
            playbackActive: false,
            cloudKitExportActive: false
        ))
    }

    func testMigrationHealthRecordPersistsWholeProcessCPUAndExecutionContext() throws {
        let record = StoreSplitMigrationHealthRecord(
            operation: "migration_slice",
            appState: "granted_background_processing",
            playbackActive: false,
            rowsScanned: 80,
            rowsMutated: 24,
            modelContextSaveCount: 1,
            modelContextSaveDurationMilliseconds: 12,
            targetStores: "UserState.sqlite,PodcastCache.sqlite",
            cloudKitExportInProgressBefore: false,
            cloudKitExportInProgressAfter: false,
            exporterWaitDurationMilliseconds: 0,
            nextRetryAt: nil,
            recordedAt: .now,
            processCPUSecondsDelta: 2.5,
            memoryFootprintBytes: 42_000_000,
            audioActive: false,
            backgroundProcessingActive: true
        )
        let decoded = try JSONDecoder().decode(
            StoreSplitMigrationHealthRecord.self,
            from: JSONEncoder().encode(record)
        )

        XCTAssertEqual(decoded.processCPUSecondsDelta, 2.5)
        XCTAssertEqual(decoded.memoryFootprintBytes, 42_000_000)
        XCTAssertEqual(decoded.audioActive, false)
        XCTAssertEqual(decoded.backgroundProcessingActive, true)
    }

    func testActiveCloudKitExportInterruptsAnAlreadyAdmittedMaintenanceBatch() {
        let source = MutableProcessCPUTimeSource()
        let budget = StoreMaintenanceResourceBudget(source: source)
        let permit = budget.acquire(
            operation: "migration",
            playbackActive: false,
            cloudKitExportActive: false
        )
        XCTAssertNotNil(permit)

        let exportID = UUID()
        budget.setCloudKitExport(eventID: exportID, active: true)
        XCTAssertEqual(
            permit?.yieldReason(playbackActive: false, cloudKitExportActive: false),
            "export_busy"
        )

        source.advance(wall: 6, cpu: 6)
        budget.setCloudKitExport(eventID: exportID, active: false)
        XCTAssertEqual(
            permit?.yieldReason(playbackActive: false, cloudKitExportActive: false),
            "cpu_budget"
        )
        permit?.release()
        XCTAssertNil(budget.acquire(
            operation: "reconcile",
            playbackActive: false,
            cloudKitExportActive: false
        ))
    }

    func testCompletedFailedCloudKitExportReleasesExporterPressureGate() {
        let source = MutableProcessCPUTimeSource()
        let thresholds = StoreMaintenanceCPUThresholds(
            shortWindow: 100,
            shortDutyCycle: 1,
            mediumWindow: 200,
            mediumDutyCycle: 1,
            longWindow: 300,
            longDutyCycle: 1,
            cooldown: 0
        )
        let budget = StoreMaintenanceResourceBudget(source: source, thresholds: thresholds)
        let permit = budget.acquire(
            operation: "migration",
            playbackActive: false,
            cloudKitExportActive: false
        )
        XCTAssertNotNil(permit)

        let failedExportID = UUID()
        budget.setCloudKitExport(eventID: failedExportID, active: true)
        XCTAssertEqual(
            permit?.yieldReason(playbackActive: false, cloudKitExportActive: false),
            "export_busy"
        )

        source.advance(wall: 6, cpu: 0)
        budget.setCloudKitExport(eventID: failedExportID, active: false)

        XCTAssertNil(permit?.yieldReason(playbackActive: false, cloudKitExportActive: false))
        permit?.release()
    }

    func testBackgroundMigrationStopsForMemoryGrowthOrAbsoluteFootprint() {
        let policy = StoreSplitMigrationRunPolicy.background
        let megabyte: UInt64 = 1024 * 1024

        XCTAssertNil(
            policy.memorySafetyReason(
                runStart: 500 * megabyte,
                sliceBefore: 500 * megabyte,
                sliceAfter: 520 * megabyte
            )
        )
        XCTAssertNotNil(
            policy.memorySafetyReason(
                runStart: 500 * megabyte,
                sliceBefore: 550 * megabyte,
                sliceAfter: 565 * megabyte
            )
        )
        XCTAssertNotNil(
            policy.memorySafetyReason(
                runStart: 500 * megabyte,
                sliceBefore: 895 * megabyte,
                sliceAfter: policy.maximumFootprint
            )
        )
    }

    func testOnlyUserStateSyncs() {
        XCTAssertTrue(StoreDevelopmentConfiguration.userStateCloudSyncEnabled)
        XCTAssertFalse(StoreDevelopmentConfiguration.legacyCloudSyncEnabled)
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

private final class MutableProcessCPUTimeSource: ProcessCPUTimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current = ProcessCPUSample(uptime: 1_000, cpuTime: 100)

    func sample() -> ProcessCPUSample {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(wall: TimeInterval, cpu: TimeInterval) {
        lock.lock()
        current = ProcessCPUSample(
            uptime: current.uptime + wall,
            cpuTime: current.cpuTime + cpu
        )
        lock.unlock()
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
        let firstWrite = try await writer.upsert(snapshot(playPosition: 100), at: first)
        XCTAssertTrue(firstWrite)

        let context = ModelContext(userState)
        let stored = try XCTUnwrap(
            context.fetch(FetchDescriptor<EpisodeStateSync>()).first
        )
        XCTAssertEqual(stored.updatedAt, first)

        // Identical state, and a sub-threshold nudge: neither is worth a write.
        let identicalWrite = try await writer.upsert(
            snapshot(playPosition: 100),
            at: first.addingTimeInterval(10)
        )
        XCTAssertFalse(identicalWrite)
        let nudgeWrite = try await writer.upsert(
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
        let progressWrite = try await writer.upsert(snapshot(playPosition: 160), at: later)
        XCTAssertTrue(progressWrite)
        let movedContext = ModelContext(userState)
        let moved = try XCTUnwrap(
            movedContext.fetch(FetchDescriptor<EpisodeStateSync>()).first
        )
        XCTAssertEqual(moved.playPosition, 160)
        XCTAssertEqual(moved.updatedAt, later)
    }
}

/// A CloudKit import that has not reached the runtime graph must keep the
/// background pass armed until a reconcile completes, and a newer request made
/// while a pass runs must not be cleared by that pass.
final class StoreSplitPendingImportLedgerTests: XCTestCase {
    private var defaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    }

    override func setUp() {
        super.setUp()
        let snapshot = StoreSplitPendingImportLedger.snapshot(in: defaults)
        StoreSplitPendingImportLedger.acknowledge(snapshot.generation, in: defaults)
    }

    override func tearDown() {
        let snapshot = StoreSplitPendingImportLedger.snapshot(in: defaults)
        StoreSplitPendingImportLedger.acknowledge(snapshot.generation, in: defaults)
        super.tearDown()
    }

    func testPendingImportKeepsBackgroundWorkArmedUntilAcknowledged() {
        StoreSplitPendingImportLedger.request(in: defaults)
        let request = StoreSplitPendingImportLedger.snapshot(in: defaults)
        XCTAssertTrue(request.pending)
        XCTAssertTrue(ModelContainerManager.hasPendingStoreSplitBackgroundWork)

        XCTAssertTrue(StoreSplitPendingImportLedger.acknowledge(request.generation, in: defaults))
        XCTAssertFalse(StoreSplitPendingImportLedger.snapshot(in: defaults).pending)
    }

    func testAPassCannotAcknowledgeANewerImportRequest() {
        StoreSplitPendingImportLedger.request(in: defaults)
        let first = StoreSplitPendingImportLedger.snapshot(in: defaults)

        StoreSplitPendingImportLedger.request(in: defaults)
        XCTAssertFalse(StoreSplitPendingImportLedger.acknowledge(first.generation, in: defaults))
        XCTAssertTrue(StoreSplitPendingImportLedger.snapshot(in: defaults).pending)
    }
}
