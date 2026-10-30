import SwiftData
import XCTest
import SQLite3
@testable import UpNext

/// After the cutover the legacy-model container is never attached to CloudKit:
/// it is either in memory or an explicit local file.
final class StoreSplitCloudReattachGuardTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearLaunchHealthDefaults()
    }

    override func tearDown() {
        clearLaunchHealthDefaults()
        super.tearDown()
    }

    func testLegacyContainerRequiresInMemoryOrAnExplicitURL() {
        XCTAssertThrowsError(try ModelContainerManager.makeLegacyContainer())
        XCTAssertNoThrow(try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true))
        XCTAssertFalse(StoreDevelopmentConfiguration.legacyCloudSyncEnabled)
    }

    func testRepeatedPreReadyLaunchesOfferRecoveryWithoutDetachingSync() {
        let base = Date(timeIntervalSince1970: 2_500)
        for offset in 0..<4 {
            XCTAssertFalse(StoreSplitLaunchHealth.beginLaunch(
                now: base.addingTimeInterval(Double(offset))
            ))
        }
        XCTAssertTrue(StoreSplitLaunchHealth.shouldOfferLegacyRecovery)
        XCTAssertTrue(StoreDevelopmentConfiguration.userStateCloudSyncEnabled)
    }

    func testRecoveryOfferSurvivesAHealthyForegroundSession() {
        let base = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(StoreSplitLaunchHealth.beginLaunch(now: base))
        XCTAssertFalse(StoreSplitLaunchHealth.beginLaunch(now: base.addingTimeInterval(1)))
        XCTAssertFalse(StoreSplitLaunchHealth.beginLaunch(now: base.addingTimeInterval(2)))
        XCTAssertTrue(StoreSplitLaunchHealth.shouldOfferLegacyRecovery)

        StoreSplitLaunchHealth.markHealthy(now: base.addingTimeInterval(100))
        XCTAssertTrue(StoreSplitLaunchHealth.shouldOfferLegacyRecovery)
    }

    func testShortUsableSessionsDoNotOfferRecovery() {
        let base = Date(timeIntervalSince1970: 1_000)
        for offset in 0..<4 {
            XCTAssertFalse(StoreSplitLaunchHealth.beginLaunch(
                now: base.addingTimeInterval(Double(offset) * 100)
            ))
            StoreSplitLaunchHealth.markRuntimeReady(
                now: base.addingTimeInterval(Double(offset) * 100 + 1)
            )
        }
        XCTAssertFalse(StoreSplitLaunchHealth.shouldOfferLegacyRecovery)
    }

    func testStoreUUIDIsUsedForCloudKitEventAttribution() {
        XCTAssertTrue(CloudKitStoreIdentity.isLegacy(
            "1234-ABCD", legacyUUID: "1234-abcd"
        ))
        XCTAssertFalse(CloudKitStoreIdentity.isLegacy(
            "user-state-uuid", legacyUUID: "1234-abcd"
        ))
    }

    func testStoreUUIDCanBeReadWithoutOpeningAMirroredContainer() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        guard let database else { return XCTFail("Could not create test store") }
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(
            database, "CREATE TABLE Z_METADATA (Z_UUID VARCHAR(255), Z_PLIST BLOB)", nil, nil, nil
        ), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(
            database, "INSERT INTO Z_METADATA (Z_UUID) VALUES ('legacy-test-uuid')",
            nil, nil, nil
        ), SQLITE_OK)
        XCTAssertEqual(
            CloudKitStoreIdentity.identifier(at: url), "legacy-test-uuid"
        )
    }

    private func clearLaunchHealthDefaults() {
        let defaults = UserDefaults(suiteName: ModelContainerManager.appGroupID)
            ?? .standard
        defaults.removeObject(forKey: StoreSplitLaunchHealth.stateKey)
        defaults.removeObject(forKey: StoreSplitLaunchHealth.recoverySuggestedKey)
        // Keep the fallback clean too when the app-group suite is unavailable
        // in a unit-test process.
        UserDefaults.standard.removeObject(forKey: StoreSplitLaunchHealth.stateKey)
        UserDefaults.standard.removeObject(forKey: StoreSplitLaunchHealth.recoverySuggestedKey)
    }
}
