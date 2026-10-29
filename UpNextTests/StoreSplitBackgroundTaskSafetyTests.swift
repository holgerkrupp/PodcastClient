import XCTest
@testable import UpNext

final class StoreSplitBackgroundTaskSafetyTests: XCTestCase {
    func testCancelledBackgroundPassCannotStartAnotherStoreOperation() {
        XCTAssertFalse(StoreSplitTaskCancellation.shouldBeginStoreWork(isCancelled: true))
        XCTAssertTrue(StoreSplitTaskCancellation.shouldBeginStoreWork(isCancelled: false))
    }

    func testImportArrivingDuringPassRemainsPendingAfterOldPassAcknowledges() throws {
        let suite = "StoreSplitPendingImportLedgerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        StoreSplitPendingImportLedger.request(in: defaults)
        let first = StoreSplitPendingImportLedger.snapshot(in: defaults)
        XCTAssertTrue(first.pending)
        XCTAssertNotNil(first.generation)

        StoreSplitPendingImportLedger.request(in: defaults, newGeneration: false)
        XCTAssertEqual(StoreSplitPendingImportLedger.snapshot(in: defaults).generation, first.generation)

        StoreSplitPendingImportLedger.request(in: defaults)
        let second = StoreSplitPendingImportLedger.snapshot(in: defaults)
        XCTAssertNotEqual(first.generation, second.generation)
        XCTAssertFalse(StoreSplitPendingImportLedger.acknowledge(first.generation, in: defaults))
        XCTAssertTrue(StoreSplitPendingImportLedger.snapshot(in: defaults).pending)

        XCTAssertTrue(StoreSplitPendingImportLedger.acknowledge(second.generation, in: defaults))
        XCTAssertFalse(StoreSplitPendingImportLedger.snapshot(in: defaults).pending)
    }
}
