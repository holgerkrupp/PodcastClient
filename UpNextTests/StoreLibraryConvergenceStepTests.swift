import Foundation
import SQLite3
import XCTest
@testable import UpNext

final class StoreLibraryConvergenceStepTests: XCTestCase {
    private var directory: URL!
    private var storeURL: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("Store.sqlite")
        suiteName = "StoreLibraryConvergenceStepTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: Index backfill

    func testBackfillRunsOnceThenLeavesTheStoreUnopened() throws {
        try makeStore(tables: ["ZEPISODE(ZPUBLISHDATE, ZPODCAST)", "ZPLAYSESSION(ZSTARTTIME)", "ZPLAYLISTENTRY(ZORDER)"])

        LegacyStoreIndexBackfill.run(storeURL: storeURL, defaults: defaults)
        XCTAssertEqual(try indexCount(), 4)

        try execute("DROP INDEX Z_PlaylistEntry_SwiftDataIndexOnBinaryorder")
        LegacyStoreIndexBackfill.run(storeURL: storeURL, defaults: defaults)

        XCTAssertEqual(try indexCount(), 3)
    }

    func testBackfillRetriesWhileATableIsMissing() throws {
        try makeStore(tables: ["ZEPISODE(ZPUBLISHDATE, ZPODCAST)", "ZPLAYSESSION(ZSTARTTIME)"])

        LegacyStoreIndexBackfill.run(storeURL: storeURL, defaults: defaults)
        XCTAssertEqual(try indexCount(), 3)

        try execute("CREATE TABLE ZPLAYLISTENTRY(ZORDER)")
        LegacyStoreIndexBackfill.run(storeURL: storeURL, defaults: defaults)

        XCTAssertEqual(try indexCount(), 4)
    }

    func testBackfillRetriesWhenTheStoreIsMissing() throws {
        LegacyStoreIndexBackfill.run(storeURL: storeURL, defaults: defaults)

        try makeStore(tables: ["ZEPISODE(ZPUBLISHDATE, ZPODCAST)", "ZPLAYSESSION(ZSTARTTIME)", "ZPLAYLISTENTRY(ZORDER)"])
        LegacyStoreIndexBackfill.run(storeURL: storeURL, defaults: defaults)

        XCTAssertEqual(try indexCount(), 4)
    }

    // MARK: Library origin

    func testAnExistingFileWithNoRecordIsLegacy() {
        XCTAssertEqual(StoreLibraryOrigin.current(libraryFileExists: true, defaults: defaults), .legacy)
    }

    func testNoFileMeansNoOriginEvenWithARecord() {
        XCTAssertNil(StoreLibraryOrigin.current(libraryFileExists: false, defaults: defaults))
        StoreLibraryOrigin.recordBuilt(defaults: defaults)
        XCTAssertNil(StoreLibraryOrigin.current(libraryFileExists: false, defaults: defaults))
    }

    func testOpeningAFileNeverOverwritesABuiltRecord() {
        StoreLibraryOrigin.recordBuilt(defaults: defaults)

        StoreLibraryOrigin.recordExistingLibraryOpened(defaults: defaults)

        XCTAssertEqual(StoreLibraryOrigin.current(libraryFileExists: true, defaults: defaults), .built)
    }

    func testOpeningAnUnrecordedFileRecordsLegacy() {
        StoreLibraryOrigin.recordExistingLibraryOpened(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: StoreLibraryOrigin.key), StoreLibraryOrigin.legacy.rawValue)
    }

    // MARK: Launch diagnostics

    func testTimerKeepsEveryStepAndTheLogSize() {
        var timer = StoreLaunchTimer()
        timer.mark("user_state")
        timer.mark("library")

        timer.finish(libraryLogBytes: 3 * 1_024 * 1_024, defaults: defaults)

        let summary = defaults.string(forKey: StoreLaunchTimer.latestKey) ?? ""
        for expected in ["user_state=", "library=", "total=", "library_log_at_start=3MB"] {
            XCTAssertTrue(summary.contains(expected), summary)
        }
    }

    func testContentsNameTablesButNoRowData() throws {
        try makeStore(tables: ["ZTRANSCRIPT(ZTEXT)"])
        try execute("INSERT INTO ZTRANSCRIPT VALUES ('My Private Show')")

        let summary = StoreLaunchDiagnostics.describeContents(storeURL: storeURL, timeLimit: 20)

        XCTAssertTrue(summary.hasPrefix("total="), summary)
        XCTAssertFalse(summary.contains("My Private Show"), summary)
    }

    func testContentsOfAMissingStoreDoNotCreateIt() {
        XCTAssertEqual(StoreLaunchDiagnostics.describeContents(storeURL: storeURL, timeLimit: 20), "unavailable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    }

    // MARK: Fixtures

    private func makeStore(tables: [String]) throws {
        for table in tables {
            try execute("CREATE TABLE \(table)")
        }
    }

    private func execute(_ sql: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(storeURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw NSError(domain: "StoreLibraryConvergenceStepTests", code: Int(result))
        }
    }

    private func indexCount() throws -> Int {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(storeURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index'"
        XCTAssertEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return Int(sqlite3_column_int(statement, 0))
    }
}
