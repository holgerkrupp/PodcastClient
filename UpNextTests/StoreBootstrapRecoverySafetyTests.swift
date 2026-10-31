import SwiftData
import XCTest
@testable import UpNext

/// Regression coverage for fail-closed store selection during launch.
final class StoreBootstrapRecoverySafetyTests: XCTestCase {
    func testMissingLegacyStoreWithOnboardingEvidenceIsUnavailable() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "didCompleteOnboarding")

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try StoreLineage.directoryContentsWithRetry(
            directory: { directory },
            expected: []
        )

        XCTAssertEqual(
            StoreBootstrapMode.resolve(
                legacyStoreExists: files.contains("SharedDatabase.sqlite"),
                installationWasPreviouslyInitialized: StoreBootstrapEvidence.mayHaveExistingLibrary(
                    standardDefaults: defaults,
                    appGroupDefaults: nil,
                    files: files
                )
            ),
            .existingLibraryUnavailable
        )
    }

    func testSplitOnlyInstallFromAnOlderBuildIsRecognized() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "didCompleteOnboarding")
        let files: Set<String> = ["UserState.sqlite", "PodcastCache.sqlite"]

        XCTAssertTrue(StoreBootstrapEvidence.hasSplitOnlyLibrary(
            standardDefaults: defaults, appGroupDefaults: defaults, files: files
        ))

        defaults.set(["UserState.sqlite", "PodcastCache.sqlite"], forKey: StoreLineage.key)
        XCTAssertTrue(StoreBootstrapEvidence.hasSplitOnlyLibrary(
            standardDefaults: defaults, appGroupDefaults: defaults, files: files
        ), "2026.36 recorded the split stores in its lineage")
    }

    func testAnySignOfALegacyStoreStaysUnavailable() throws {
        let files: Set<String> = ["UserState.sqlite", "PodcastCache.sqlite"]
        let signs: [(UserDefaults) -> Void] = [
            { $0.set(["SharedDatabase.sqlite"], forKey: StoreLineage.key) },
            { $0.set(false, forKey: StoreDevelopmentConfiguration.legacyCloudSyncLastStateKey) },
            { $0.set(true, forKey: StoreDevelopmentConfiguration.legacyCloudSyncLastStateKey) },
            { $0.set(true, forKey: StoreBootstrapEvidence.persistentLibraryOpenedKey) }
        ]
        for sign in signs {
            let (suiteName, defaults) = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            sign(defaults)
            XCTAssertFalse(StoreBootstrapEvidence.hasSplitOnlyLibrary(
                standardDefaults: defaults, appGroupDefaults: defaults, files: files
            ))
        }

        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertFalse(StoreBootstrapEvidence.hasSplitOnlyLibrary(
            standardDefaults: defaults, appGroupDefaults: defaults, files: ["PodcastCache.sqlite"]
        ), "without UserState there is nothing to restore subscriptions from")
        XCTAssertFalse(StoreBootstrapEvidence.hasSplitOnlyLibrary(
            standardDefaults: defaults, appGroupDefaults: defaults,
            files: files.union(["SharedDatabase.sqlite-wal"])
        ))
    }

    func testCopyCheckpointsThatScannedRowsProveALegacyLibrary() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("PodcastCache.sqlite")
        let container = try ModelContainerManager.makeCacheContainer(storageURL: url)
        let context = ModelContext(container)
        context.insert(StoreSplitMigrationCheckpoint(id: "empty", migrationVersion: 1, phase: "subscriptions"))
        try context.save()
        XCTAssertFalse(StoreBootstrapEvidence.cacheRecordsLegacyCopy(at: url))

        context.insert(StoreSplitMigrationCheckpoint(
            id: "scanned", migrationVersion: 1, phase: "playlists", scannedCount: 5
        ))
        try context.save()
        XCTAssertTrue(StoreBootstrapEvidence.cacheRecordsLegacyCopy(at: url))

        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertFalse(StoreBootstrapEvidence.hasSplitOnlyLibrary(
            standardDefaults: defaults,
            appGroupDefaults: defaults,
            files: ["UserState.sqlite", "PodcastCache.sqlite"],
            cacheURL: url
        ))
    }

    func testUnreadableCacheCountsAsProof() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("PodcastCache.sqlite")
        try Data("not a database".utf8).write(to: url)
        XCTAssertTrue(StoreBootstrapEvidence.cacheRecordsLegacyCopy(at: url))
    }

    func testContinuingWithoutTheLegacyLibraryOpensAndALegacyStoreStillWins() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        StoreBootstrapEvidence.continueWithoutLegacyLibrary(defaults: defaults)
        let hasRecord = StoreBootstrapEvidence.hasFreshSplitInstallRecord(defaults: defaults)

        XCTAssertEqual(
            StoreBootstrapMode.resolve(
                legacyStoreExists: false,
                installationWasPreviouslyInitialized: !hasRecord
            ),
            .freshSplitInstall
        )
        XCTAssertEqual(
            StoreBootstrapMode.resolve(
                legacyStoreExists: true,
                installationWasPreviouslyInitialized: !hasRecord
            ),
            .legacyUpgrade
        )
    }

    func testMissingPodcastCacheDoesNotBlockOpeningButMissingUserStateDoes() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("UserState.sqlite"))
        let opened = ["UserState.sqlite", "PodcastCache.sqlite"]

        XCTAssertNoThrow(try StoreLineage.validate(
            directory: directory,
            expected: StoreLineage.requiredStores(opened)
        ))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("UserState.sqlite"))
        XCTAssertThrowsError(try StoreLineage.validate(
            directory: directory,
            expected: StoreLineage.requiredStores(opened)
        ))
    }

    /// The feed cache may be empty: everything the user made comes from UserState.
    @MainActor
    func testSubscriptionsAndPlaylistsSurviveARebuildWithAnEmptyCache() async throws {
        let cache = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let runtime = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let feed = "https://example.com/split-only.xml"
        let subscription = SubscriptionSync(feedURL: feed)
        subscription.isSubscribed = true
        userState.mainContext.insert(subscription)
        userState.mainContext.insert(PlaylistSync(
            id: Playlist.defaultQueueSyncID,
            title: Playlist.defaultQueueTitle,
            symbolName: Playlist.defaultQueueSymbolName,
            sortIndex: 0,
            kindRawValue: Playlist.Kind.manual.rawValue
        ))
        userState.mainContext.insert(PlaylistEntrySync(
            playlistID: Playlist.defaultQueueSyncID,
            feedURL: feed,
            episodeID: "not-fetched-yet",
            sortIndex: 0
        ))
        try userState.mainContext.save()

        XCTAssertEqual(
            StoreSplitCompatibilityProjectionService.rebuild(
                cacheContainer: cache,
                runtimeContainer: runtime
            ).failed,
            0
        )
        let result = await StoreSplitUserStateImporter.apply(
            legacyContainer: runtime,
            userStateContainer: userState,
            authoritativePlaylists: true
        )

        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.feedsToBootstrap.map(\.absoluteString), [feed])
        let podcasts = try ModelContext(runtime).fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(podcasts.filter { $0.metaData?.isSubscribed == true }.count, 1)
        let account = ModelContext(userState)
        XCTAssertEqual(try account.fetch(FetchDescriptor<SubscriptionSync>()).filter(\.isSubscribed).count, 1)
        let entries = try account.fetch(FetchDescriptor<PlaylistEntrySync>())
        XCTAssertEqual(entries.map(\.episodeID), ["not-fetched-yet"])
        XCTAssertTrue(entries.allSatisfy { $0.isDeleted == false })
    }

    func testCompletedFreshSplitMarkerAllowsFreshInstallDespiteOldOnboardingEvidence() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "didCompleteOnboarding")
        defaults.set(true, forKey: StoreBootstrapEvidence.freshSplitInstallReadyKey)

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try StoreLineage.directoryContentsWithRetry(
            directory: { directory },
            expected: []
        )
        let hadPriorEvidence = StoreBootstrapEvidence.mayHaveExistingLibrary(
            standardDefaults: defaults,
            appGroupDefaults: nil,
            files: files
        )

        XCTAssertTrue(hadPriorEvidence)
        XCTAssertEqual(
            StoreBootstrapMode.resolve(
                legacyStoreExists: false,
                installationWasPreviouslyInitialized: hadPriorEvidence
                    && !StoreBootstrapEvidence.hasFreshSplitInstallRecord(defaults: defaults)
            ),
            .freshSplitInstall
        )
    }

    @MainActor
    func testPresentDiskBackedLegacyStoreRemainsSelectedAndSubscriptionsStayReadable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("SharedDatabase.sqlite")

        do {
            let original = try ModelContainerManager.makeLegacyContainer(storageURL: storeURL)
            let podcast = Podcast(feed: URL(string: "https://example.com/bootstrap-fixture.xml")!)
            podcast.title = "Offline bootstrap fixture"
            original.mainContext.insert(podcast)
            try original.mainContext.save()
        }

        let files = try StoreLineage.directoryContentsWithRetry(
            directory: { directory },
            expected: ["SharedDatabase.sqlite"]
        )
        XCTAssertEqual(
            StoreBootstrapMode.resolve(
                legacyStoreExists: files.contains("SharedDatabase.sqlite"),
                installationWasPreviouslyInitialized: false
            ),
            .legacyUpgrade
        )

        let reopened = try ModelContainerManager.makeLegacyContainer(storageURL: storeURL)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<Podcast>()), 1)
    }

    private func makeDefaults() throws -> (String, UserDefaults) {
        let suiteName = "StoreBootstrapRecovery-\(UUID().uuidString)"
        return (suiteName, try XCTUnwrap(UserDefaults(suiteName: suiteName)))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastClient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
