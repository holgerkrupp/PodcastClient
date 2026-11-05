import Foundation
import XCTest
@testable import UpNext

/// The weekly storage cleanup deleted every App Group file except
/// `SharedDatabase.sqlite*`, including UserState, PodcastCache and the runtime
/// library. The next launch then stopped on "could not access persistent storage".
final class StoreFileSafetyTests: XCTestCase {
    func testEveryStoreAndSidecarCountsAsADatabase() {
        for name in ["SharedDatabase.sqlite", "UserState.sqlite-wal", "PodcastCache.sqlite-shm", "LibraryRuntime.sqlite"] {
            XCTAssertTrue(StorageManagementService.isStoreFile(name), name)
        }
        XCTAssertFalse(StorageManagementService.isStoreFile("episode.mp3"))
    }

    func testCleanupInTheAppGroupIsLimitedToEpisodeFiles() {
        XCTAssertFalse(StorageManagementService.isManagedFile(in: .shared, belongsToEpisode: false))
        XCTAssertTrue(StorageManagementService.isManagedFile(in: .shared, belongsToEpisode: true))
        XCTAssertTrue(StorageManagementService.isManagedFile(in: .caches, belongsToEpisode: false))
        XCTAssertTrue(StorageManagementService.isManagedFile(in: .documents, belongsToEpisode: false))
    }

    func testAReadableDirectoryWithoutAKnownStoreReportsWhichIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        FileManager.default.createFile(atPath: directory.appendingPathComponent("PodcastCache.sqlite").path, contents: Data())

        XCTAssertThrowsError(try StoreLineage.directoryContentsWithRetry(
            directory: { directory },
            expected: ["UserState.sqlite"],
            attempts: 1
        )) { error in
            XCTAssertEqual(error as? StoreLineageMissingStores, StoreLineageMissingStores(names: ["UserState.sqlite"]))
        }
    }

    func testContinuingAcceptsOnlyTheStoresThatWereMissingUntilTheyReturn() throws {
        let suiteName = "StoreFileSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        StoreLineage.recordMissingStores(["UserState.sqlite"], defaults: defaults)
        XCTAssertTrue(StoreLineage.acceptedMissingStores(defaults: defaults).isEmpty, "Nothing is accepted without the owner's choice")

        StoreBootstrapEvidence.continueWithoutLegacyLibrary(defaults: defaults)
        XCTAssertEqual(StoreLineage.acceptedMissingStores(defaults: defaults), ["UserState.sqlite"])

        StoreLineage.forgetAcceptedStores(present: ["UserState.sqlite"], defaults: defaults)
        XCTAssertTrue(StoreLineage.acceptedMissingStores(defaults: defaults).isEmpty)
    }
}
