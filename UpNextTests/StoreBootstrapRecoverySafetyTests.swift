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
                ),
                legacyCloudCutoverCompleted: false,
                releasePhaseIsPostCutover: false
            ),
            .existingLibraryUnavailable
        )
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
                    && !StoreBootstrapEvidence.hasFreshSplitInstallRecord(defaults: defaults),
                legacyCloudCutoverCompleted: false,
                releasePhaseIsPostCutover: false
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
                installationWasPreviouslyInitialized: false,
                legacyCloudCutoverCompleted: false,
                releasePhaseIsPostCutover: false
            ),
            .legacyUpgrade
        )

        let reopened = try ModelContainerManager.makeLegacyContainer(storageURL: storeURL)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<Podcast>()), 1)
    }

    @MainActor
    func testQuarantinedCloudMirrorDoesNotPreventOpeningLocalLegacyStore() throws {
        let groupDefaults = try XCTUnwrap(
            UserDefaults(suiteName: ModelContainerManager.appGroupID)
        )
        let previousValue = groupDefaults.object(
            forKey: StoreDevelopmentConfiguration.legacyCloudMirrorQuarantinedKey
        )
        defer {
            if let previousValue {
                groupDefaults.set(
                    previousValue,
                    forKey: StoreDevelopmentConfiguration.legacyCloudMirrorQuarantinedKey
                )
            } else {
                groupDefaults.removeObject(
                    forKey: StoreDevelopmentConfiguration.legacyCloudMirrorQuarantinedKey
                )
            }
        }
        groupDefaults.set(
            true,
            forKey: StoreDevelopmentConfiguration.legacyCloudMirrorQuarantinedKey
        )
        XCTAssertTrue(StoreDevelopmentConfiguration.legacyCloudMirrorQuarantined)

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("SharedDatabase.sqlite")
        do {
            let original = try ModelContainerManager.makeLegacyContainer(storageURL: storeURL)
            let podcast = Podcast(feed: URL(string: "https://example.com/quarantine-fixture.xml")!)
            podcast.title = "Offline quarantine fixture"
            original.mainContext.insert(podcast)
            try original.mainContext.save()
        }

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
