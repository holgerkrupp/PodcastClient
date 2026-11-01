import Foundation
import SQLite3
import XCTest
@testable import UpNext

final class StoreWriteAheadLogTests: XCTestCase {
    private var directory: URL!
    private var storeURL: URL!
    private var writer: OpaquePointer?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("Store.sqlite")
        XCTAssertEqual(sqlite3_open(storeURL.path, &writer), SQLITE_OK)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA wal_autocheckpoint=0")
        try execute("CREATE TABLE item (value TEXT)")
    }

    override func tearDownWithError() throws {
        sqlite3_close(writer)
        try FileManager.default.removeItem(at: directory)
    }

    func testTrimEmptiesTheLogAndKeepsEveryRow() throws {
        try insertRows(50)
        XCTAssertGreaterThan(StoreWriteAheadLog.sizeInBytes(storeURL: storeURL), 0)

        XCTAssertEqual(StoreWriteAheadLog.trim(storeURL: storeURL, thresholdBytes: 1), .trimmed)

        XCTAssertEqual(StoreWriteAheadLog.sizeInBytes(storeURL: storeURL), 0)
        XCTAssertEqual(try rowCount(), 50)
    }

    func testLogBelowTheThresholdIsLeftAlone() throws {
        try insertRows(1)
        let size = StoreWriteAheadLog.sizeInBytes(storeURL: storeURL)

        XCTAssertEqual(StoreWriteAheadLog.trim(storeURL: storeURL, thresholdBytes: size + 1), .belowThreshold)

        XCTAssertEqual(StoreWriteAheadLog.sizeInBytes(storeURL: storeURL), size)
    }

    func testOpenReadBlocksTheTrimWithoutLosingWrites() throws {
        try insertRows(1)
        var reader: OpaquePointer?
        XCTAssertEqual(sqlite3_open(storeURL.path, &reader), SQLITE_OK)
        defer { sqlite3_close(reader) }
        XCTAssertEqual(sqlite3_exec(reader, "BEGIN; SELECT COUNT(*) FROM item;", nil, nil, nil), SQLITE_OK)
        try insertRows(5)

        XCTAssertEqual(StoreWriteAheadLog.trim(storeURL: storeURL, thresholdBytes: 1), .busy)
        XCTAssertEqual(try rowCount(), 6)

        XCTAssertEqual(sqlite3_exec(reader, "COMMIT", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(StoreWriteAheadLog.trim(storeURL: storeURL, thresholdBytes: 1), .trimmed)
        XCTAssertEqual(try rowCount(), 6)
    }

    func testMissingStoreIsNotCreated() {
        let missing = directory.appendingPathComponent("Missing.sqlite")

        XCTAssertEqual(StoreWriteAheadLog.trim(storeURL: missing, thresholdBytes: 0), .failed)

        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    private func insertRows(_ count: Int) throws {
        for _ in 0..<count {
            try execute("INSERT INTO item VALUES (hex(randomblob(2000)))")
        }
    }

    private func rowCount() throws -> Int {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(writer, "SELECT COUNT(*) FROM item", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return Int(sqlite3_column_int(statement, 0))
    }

    private func execute(_ sql: String) throws {
        let result = sqlite3_exec(writer, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw NSError(domain: "StoreWriteAheadLogTests", code: Int(result))
        }
    }
}
