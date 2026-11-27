import XCTest
@testable import UpNext

/// #518: an established library opens without network waits or optional
/// maintenance in front of the first usable UI, while reset safety holds.
final class StoreLaunchCriticalPathTests: XCTestCase {
    // MARK: Established libraries, second launch

    func testEstablishedLegacyAndBuiltLibrariesSkipTheCacheAndItsMigrations() {
        for mode in [StoreBootstrapMode.legacyUpgrade, .builtLibrary] {
            let complete = StoreCacheOpenDecision.cacheWorkIsComplete(
                bootstrapMode: mode,
                hasEverReset: false,
                localDataMigrationComplete: true,
                aiContentMigrationComplete: true,
                cacheRecoveryComplete: true,
                legacyCopyPending: false,
                libraryBackfillPending: false,
                firstBuildPending: false
            )
            XCTAssertTrue(complete, "\(mode)")
            XCTAssertEqual(
                StoreCacheOpenDecision.resolve(
                    hasEverReset: false,
                    migrationsComplete: complete,
                    cacheFileExists: true,
                    legacyCopyNeedsCheckpointStore: false
                ),
                .skipMigrationsComplete,
                "\(mode): a historical cache file must not be opened again"
            )
            XCTAssertFalse(
                ModelContainerManager.deferredCacheMigrationsArePending(
                    bootstrapMode: mode,
                    isFirstLibraryBuild: false,
                    hasEverReset: false,
                    cacheIsOpen: false,
                    localDataMigrationComplete: true,
                    aiContentMigrationComplete: true
                ),
                "\(mode): no migration runs on a completed library"
            )
        }
    }

    /// A first launch that found no cache records the migrations complete, so
    /// the second launch takes the established path instead of retrying.
    func testMissingCacheOnFirstLaunchLeavesNothingForTheSecondLaunch() {
        XCTAssertEqual(
            StoreCacheOpenDecision.resolve(
                hasEverReset: false,
                migrationsComplete: false,
                cacheFileExists: false,
                legacyCopyNeedsCheckpointStore: false
            ),
            .skipFileAbsent
        )
        // `.skipFileAbsent` marks both migrations and cache recovery complete.
        let secondLaunch = StoreCacheOpenDecision.cacheWorkIsComplete(
            bootstrapMode: .builtLibrary,
            hasEverReset: false,
            localDataMigrationComplete: true,
            aiContentMigrationComplete: true,
            cacheRecoveryComplete: true,
            legacyCopyPending: false,
            libraryBackfillPending: false,
            firstBuildPending: false
        )
        XCTAssertTrue(secondLaunch)
    }

    /// Unfinished cache work still opens the cache, but its migrations are
    /// post-launch work and a fresh build is never treated as established.
    func testUnfinishedCacheWorkIsDeferredAndFreshBuildsAreNotEstablished() {
        XCTAssertFalse(StoreCacheOpenDecision.cacheWorkIsComplete(
            bootstrapMode: .legacyUpgrade,
            hasEverReset: false,
            localDataMigrationComplete: false,
            aiContentMigrationComplete: true,
            cacheRecoveryComplete: true,
            legacyCopyPending: false,
            libraryBackfillPending: false,
            firstBuildPending: false
        ))
        XCTAssertFalse(StoreCacheOpenDecision.cacheWorkIsComplete(
            bootstrapMode: .freshSplitInstall,
            hasEverReset: false,
            localDataMigrationComplete: true,
            aiContentMigrationComplete: true,
            cacheRecoveryComplete: true,
            legacyCopyPending: false,
            libraryBackfillPending: false,
            firstBuildPending: false
        ))
        XCTAssertTrue(ModelContainerManager.deferredCacheMigrationsArePending(
            bootstrapMode: .legacyUpgrade,
            isFirstLibraryBuild: false,
            hasEverReset: false,
            cacheIsOpen: true,
            localDataMigrationComplete: false,
            aiContentMigrationComplete: true
        ))
        // A reset device never copies historical rows back.
        XCTAssertFalse(ModelContainerManager.deferredCacheMigrationsArePending(
            bootstrapMode: .legacyUpgrade,
            isFirstLibraryBuild: false,
            hasEverReset: true,
            cacheIsOpen: true,
            localDataMigrationComplete: false,
            aiContentMigrationComplete: false
        ))
        // The first build owns its own cache seed.
        XCTAssertFalse(ModelContainerManager.deferredCacheMigrationsArePending(
            bootstrapMode: .builtLibrary,
            isFirstLibraryBuild: true,
            hasEverReset: false,
            cacheIsOpen: true,
            localDataMigrationComplete: false,
            aiContentMigrationComplete: false
        ))
    }

    // MARK: Remote reset fence

    func testReachableCloudKitCompletesTheFenceCheckBeforeOpening() async {
        let gate = DeleteAllDataService.LaunchFenceGate()
        let outcome = await gate.check(deadline: .seconds(5)) {}
        XCTAssertEqual(outcome, .completed)
        XCTAssertFalse(gate.isUnresolved)
    }

    func testUnreachableCloudKitDoesNotBlockOpening() async {
        let gate = DeleteAllDataService.LaunchFenceGate()
        let started = ContinuousClock.now
        let outcome = await gate.check(deadline: .milliseconds(150)) {
            try? await Task.sleep(for: .seconds(60))
        }
        XCTAssertEqual(outcome, .deferred)
        XCTAssertLessThan(started.duration(to: .now), .seconds(3))
        // Still running: portable publication must wait for it.
        XCTAssertTrue(gate.isUnresolved)
        XCTAssertFalse(DeleteAllDataService.mayPublishPortableState(
            hasPendingLocalReset: false,
            launchFenceUnresolved: gate.isUnresolved
        ))
        // The bounded wait returns even when CloudKit never answers.
        let waitStarted = ContinuousClock.now
        await gate.waitIfUnresolved(limit: .milliseconds(150))
        XCTAssertLessThan(waitStarted.duration(to: .now), .seconds(3))
    }

    func testLateFenceResultResolvesTheGate() async {
        let gate = DeleteAllDataService.LaunchFenceGate()
        let outcome = await gate.check(deadline: .milliseconds(50)) {
            try? await Task.sleep(for: .milliseconds(300))
        }
        XCTAssertEqual(outcome, .deferred)
        await gate.waitIfUnresolved(limit: .seconds(10))
        XCTAssertFalse(gate.isUnresolved)
        XCTAssertTrue(DeleteAllDataService.mayPublishPortableState(
            hasPendingLocalReset: false,
            launchFenceUnresolved: gate.isUnresolved
        ))
    }

    func testKnownPendingResetAlwaysGatesPublication() {
        for unresolved in [false, true] {
            XCTAssertFalse(DeleteAllDataService.mayPublishPortableState(
                hasPendingLocalReset: true,
                launchFenceUnresolved: unresolved
            ))
        }
    }

    // MARK: Diagnostics

    func testTimerKeepsAnUnfinishedOpeningForTheNextReport() throws {
        let suiteName = "StoreLaunchCriticalPathTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var interrupted = StoreLaunchTimer(defaults: defaults)
        interrupted.mark("remote_fence_wait")
        interrupted.note("remote_fence=deferred")
        XCTAssertEqual(
            defaults.string(forKey: StoreLaunchTimer.inProgressKey)?.contains("remote_fence=deferred"),
            true
        )

        var next = StoreLaunchTimer(defaults: defaults)
        let kept = defaults.string(forKey: StoreLaunchTimer.interruptedKey) ?? ""
        XCTAssertTrue(kept.contains("remote_fence_wait="), kept)
        next.mark("library")
        next.finish(libraryLogBytes: 0)
        XCTAssertNil(defaults.string(forKey: StoreLaunchTimer.inProgressKey))
        XCTAssertTrue((defaults.string(forKey: StoreLaunchTimer.latestKey) ?? "").contains("library="))
    }

    // MARK: Unopenable historical cache (#394)

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "StoreCacheBackoff-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testCorruptCacheIsRetriedOnlyUntilTheLimitAndAgainWhenTheFileChanges() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let signature = "100:1:42"
        for attempt in 1...StoreCacheOpenBackoff.maximumConsecutiveFailures {
            XCTAssertTrue(
                StoreCacheOpenBackoff.shouldAttemptOpen(currentSignature: signature, defaults: defaults),
                "attempt \(attempt) is still tried"
            )
            StoreCacheOpenBackoff.recordOpenFailed(signature: signature, dataIsReadable: true, defaults: defaults)
        }
        XCTAssertFalse(StoreCacheOpenBackoff.shouldAttemptOpen(currentSignature: signature, defaults: defaults))
        // A restored/replaced file or a new build is tried again, and counts afresh.
        XCTAssertTrue(StoreCacheOpenBackoff.shouldAttemptOpen(currentSignature: "200:2:42", defaults: defaults))
        XCTAssertTrue(StoreCacheOpenBackoff.shouldAttemptOpen(currentSignature: "100:1:43", defaults: defaults))
        StoreCacheOpenBackoff.recordOpenFailed(signature: "200:2:42", dataIsReadable: true, defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: StoreCacheOpenBackoff.failuresKey), 1)
        // A successful open forgets every failure.
        StoreCacheOpenBackoff.recordOpenSucceeded(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: StoreCacheOpenBackoff.failuresKey))
    }

    func testProtectedOrUnreadableCacheNeverCountsTowardsGivingUp() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        for _ in 0..<10 {
            StoreCacheOpenBackoff.recordOpenFailed(signature: "100:1:42", dataIsReadable: false, defaults: defaults)
            StoreCacheOpenBackoff.recordOpenFailed(signature: nil, dataIsReadable: true, defaults: defaults)
        }
        XCTAssertTrue(StoreCacheOpenBackoff.shouldAttemptOpen(currentSignature: "100:1:42", defaults: defaults))
    }

    func testSignatureFollowsTheFileAndTheBuild() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreCacheBackoff-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(StoreCacheOpenBackoff.signature(of: url, build: "1"))
        XCTAssertFalse(StoreCacheOpenBackoff.fileDataIsReadable(url))
        try Data("not a database".utf8).write(to: url)
        let first = try XCTUnwrap(StoreCacheOpenBackoff.signature(of: url, build: "1"))
        XCTAssertTrue(StoreCacheOpenBackoff.fileDataIsReadable(url))
        XCTAssertEqual(StoreCacheOpenBackoff.signature(of: url, build: "1"), first)
        XCTAssertNotEqual(StoreCacheOpenBackoff.signature(of: url, build: "2"), first)
        try Data("a longer replacement file".utf8).write(to: url)
        XCTAssertNotEqual(StoreCacheOpenBackoff.signature(of: url, build: "1"), first)
    }

    func testGivenUpCacheIsNotOpenedEvenWhileALegacyCopyIsPending() {
        for copyPending in [false, true] {
            XCTAssertEqual(
                StoreCacheOpenDecision.resolve(
                    hasEverReset: false,
                    migrationsComplete: false,
                    cacheFileExists: true,
                    legacyCopyNeedsCheckpointStore: copyPending,
                    openIsBackedOff: true
                ),
                .skipAfterRepeatedOpenFailures
            )
        }
        // A missing file on a pending-copy device is still created for checkpoints.
        XCTAssertEqual(
            StoreCacheOpenDecision.resolve(
                hasEverReset: false,
                migrationsComplete: false,
                cacheFileExists: false,
                legacyCopyNeedsCheckpointStore: true,
                openIsBackedOff: true
            ),
            .open
        )
    }

    func testLegacyCopyUsesTemporaryCheckpointsOnlyForAGivenUpCacheAndBoundedTimes() {
        XCTAssertEqual(
            ModelContainerManager.legacyCopyCheckpointSource(
                cacheIsOpen: true, cacheOpenGivenUp: false, temporaryCheckpointAttempts: 0
            ),
            .cache
        )
        XCTAssertEqual(
            ModelContainerManager.legacyCopyCheckpointSource(
                cacheIsOpen: false, cacheOpenGivenUp: false, temporaryCheckpointAttempts: 0
            ),
            .waitForCache,
            "a transient failure retries the real cache next launch"
        )
        XCTAssertEqual(
            ModelContainerManager.legacyCopyCheckpointSource(
                cacheIsOpen: false, cacheOpenGivenUp: true, temporaryCheckpointAttempts: 0
            ),
            .temporaryCheckpoints
        )
        XCTAssertEqual(
            ModelContainerManager.legacyCopyCheckpointSource(
                cacheIsOpen: false,
                cacheOpenGivenUp: true,
                temporaryCheckpointAttempts: ModelContainerManager.maximumTemporaryCheckpointAttempts
            ),
            .waitForCache,
            "whole-library re-scans are bounded"
        )
    }

    func testUnresolvedCacheRowsAreOnlyAbandonedOnceTheLibraryIsComplete() {
        XCTAssertTrue(ModelContainerManager.cacheMigrationTargetLibraryIsComplete(
            isFirstLibraryBuild: false, firstBuildPending: false, libraryBackfillPending: false
        ))
        XCTAssertFalse(ModelContainerManager.cacheMigrationTargetLibraryIsComplete(
            isFirstLibraryBuild: true, firstBuildPending: false, libraryBackfillPending: false
        ))
        XCTAssertFalse(ModelContainerManager.cacheMigrationTargetLibraryIsComplete(
            isFirstLibraryBuild: false, firstBuildPending: true, libraryBackfillPending: false
        ))
        XCTAssertFalse(ModelContainerManager.cacheMigrationTargetLibraryIsComplete(
            isFirstLibraryBuild: false, firstBuildPending: false, libraryBackfillPending: true
        ))
    }
}
