import Foundation
import XCTest
@testable import UpNext

final class RefreshHistoryStoreTests: XCTestCase {
    func testBeginPersistsImmediatelyAndFinishUpdatesInPlace() async throws {
        let testDefaults = try makeDefaults()
        let defaults = testDefaults.defaults
        let store = RefreshHistoryStore(suiteName: testDefaults.suiteName)
        let id = UUID()

        await store.begin(
            id: id,
            startedAt: Date(timeIntervalSince1970: 10),
            trigger: .userInitiatedBulk,
            total: 2
        )

        let persistedAfterBegin = try XCTUnwrap(defaults.data(forKey: "DevelopmentRefreshHistory.v1"))
        let firstSnapshot = try JSONDecoder().decode([RefreshHistoryEntry].self, from: persistedAfterBegin)
        XCTAssertEqual(firstSnapshot.count, 1)
        XCTAssertEqual(firstSnapshot[0].status, .inProgress)

        await store.update(
            id: id,
            completed: 1,
            total: 2,
            podcast: RefreshHistoryPodcastCheck(
                title: "Example Show",
                feedURL: URL(string: "https://example.com/feed.xml")!,
                result: .feedNotUpdated
            )
        )
        await store.finish(id: id, status: .completed, completed: 2, total: 2)

        let entries = await store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, id)
        XCTAssertEqual(entries[0].status, .completed)
        XCTAssertEqual(entries[0].completed, 2)
        XCTAssertEqual(entries[0].checkedPodcasts.count, 1)
    }

    func testProgressPersistenceCanBeCoalescedAndFlushed() async throws {
        let testDefaults = try makeDefaults()
        let defaults = testDefaults.defaults
        let store = RefreshHistoryStore(suiteName: testDefaults.suiteName)
        let id = await store.begin(trigger: .userInitiatedBulk, total: 3)

        await store.update(id: id, completed: 1, total: 3)
        let beforeFlush = try XCTUnwrap(defaults.data(forKey: "DevelopmentRefreshHistory.v1"))
        let staleEntries = try JSONDecoder().decode([RefreshHistoryEntry].self, from: beforeFlush)
        XCTAssertEqual(staleEntries[0].completed, 0)

        await store.flush()
        let afterFlush = try XCTUnwrap(defaults.data(forKey: "DevelopmentRefreshHistory.v1"))
        let flushedEntries = try JSONDecoder().decode([RefreshHistoryEntry].self, from: afterFlush)
        XCTAssertEqual(flushedEntries[0].completed, 1)
    }

    func testUnfinishedEntriesRecoverAsInterruptedAndActiveEntriesSortFirst() async throws {
        let testDefaults = try makeDefaults()
        let defaults = testDefaults.defaults
        let store = RefreshHistoryStore(suiteName: testDefaults.suiteName)
        let older = await store.begin(
            startedAt: Date(timeIntervalSince1970: 20),
            trigger: .backgroundAppRefresh
        )
        await store.finish(
            id: older,
            status: .completed,
            finishedAt: Date(timeIntervalSince1970: 21)
        )
        _ = await store.begin(
            startedAt: Date(timeIntervalSince1970: 10),
            trigger: .userInitiatedBulk
        )

        let recoveredStore = RefreshHistoryStore(suiteName: testDefaults.suiteName)
        let recovered = await recoveredStore.entries()

        XCTAssertEqual(recovered.count, 2)
        XCTAssertEqual(recovered[0].status, .interrupted)
        XCTAssertEqual(recovered[1].status, .completed)

        let persisted = try XCTUnwrap(defaults.data(forKey: "DevelopmentRefreshHistory.v1"))
        let persistedEntries = try JSONDecoder().decode([RefreshHistoryEntry].self, from: persisted)
        XCTAssertEqual(persistedEntries[0].status, .interrupted)
    }

    func testDuplicateBeginAndFinishDoNotCreateOrAppendEntries() async throws {
        let testDefaults = try makeDefaults()
        let defaults = testDefaults.defaults
        let store = RefreshHistoryStore(suiteName: testDefaults.suiteName)
        let id = UUID()

        await store.begin(id: id, trigger: .userInitiatedBulk)
        await store.begin(id: id, trigger: .userInitiatedBulk)
        await store.finish(id: id, status: .completed)
        await store.finish(id: id, status: .failed)

        let entries = await store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].status, .completed)
    }

    private func makeDefaults() throws -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = "RefreshHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName: suiteName, defaults: defaults)
    }
}
