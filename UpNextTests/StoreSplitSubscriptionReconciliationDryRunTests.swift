import Foundation
import SwiftData
import XCTest
@testable import UpNext

private final class SubscriptionReconciliationOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true

    func shouldContinue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard available else { return false }
        available = false
        return true
    }
}

final class StoreSplitSubscriptionReconciliationDryRunTests: XCTestCase {
    private struct Stores {
        let legacy: ModelContainer
        let user: ModelContainer
        let cache: ModelContainer
    }

    @MainActor
    private func makeStores() throws -> Stores {
        Stores(
            legacy: try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true),
            user: try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true),
            cache: try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        )
    }

    @MainActor
    private func source(_ feed: String, date: Date, context: ModelContext) {
        let podcast = Podcast(feed: URL(string: feed)!)
        podcast.metaData?.subscriptionDate = date
        podcast.metaData?.isSubscribed = true
        context.insert(podcast)
    }

    @MainActor
    private func portable(
        _ feed: String,
        date: Date,
        updatedAt: Date,
        accessProfileID: String? = nil,
        subscribed: Bool = true,
        unsubscribedAt: Date? = nil,
        context: ModelContext
    ) {
        context.insert(SubscriptionSync(
            feedURL: feed, accessProfileID: accessProfileID,
            isSubscribed: subscribed, subscribedAt: date,
            unsubscribedAt: unsubscribedAt, updatedAt: updatedAt
        ))
    }

    @MainActor
    func testPagedDiffClassifiesFieldsAndPreservesOtherDeviceRows() async throws {
        let stores = try makeStores()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = stores.legacy.mainContext
        let user = stores.user.mainContext
        for letter in ["a", "b", "c"] {
            source("https://\(letter).example/feed.xml", date: date, context: legacy)
        }
        portable("https://a.example/feed.xml", date: date, updatedAt: date, context: user)
        portable("https://b.example/feed.xml", date: date, updatedAt: date.addingTimeInterval(10),
                 accessProfileID: "new-profile", context: user)
        portable("https://c.example/feed.xml", date: date, updatedAt: date,
                 accessProfileID: "different-profile", context: user)
        portable("https://d.example/feed.xml", date: date, updatedAt: date, context: user)
        portable("https://e.example/feed.xml", date: date, updatedAt: date,
                 subscribed: false, unsubscribedAt: date, context: user)
        portable("https://f.example/feed.xml", date: date, updatedAt: date,
                 subscribed: false, context: user)
        try legacy.save()
        try user.save()

        let first = await StoreSplitSubscriptionReconciliationDryRun.runPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user,
            cacheContainer: stores.cache, pageSize: 2
        )
        XCTAssertEqual(first.status, .advanced)
        XCTAssertEqual(first.progress.matching, 1)
        XCTAssertEqual(first.progress.newerDestination, 1)
        let second = await StoreSplitSubscriptionReconciliationDryRun.runPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user,
            cacheContainer: stores.cache, pageSize: 2
        )
        XCTAssertEqual(second.status, .advanced)
        XCTAssertEqual(second.progress.semanticConflicts, 1)
        XCTAssertEqual(second.progress.unresolvedLineage, 1)
        let third = await StoreSplitSubscriptionReconciliationDryRun.runPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user,
            cacheContainer: stores.cache, pageSize: 2
        )
        XCTAssertEqual(third.status, .traversalCompleted)
        XCTAssertEqual(third.progress.scanned, 6)
        XCTAssertEqual(third.progress.tombstonesPreserved, 1)
        XCTAssertEqual(third.progress.inconsistentTombstones, 1)
        XCTAssertEqual(try ModelContext(stores.user).fetchCount(FetchDescriptor<SubscriptionSync>()), 6)
        let checkpointID = StoreSplitSubscriptionReconciliationDryRun.checkpointID
        let checkpoint = try XCTUnwrap(ModelContext(stores.cache).fetch(
            FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == checkpointID })
        ).first)
        XCTAssertEqual(checkpoint.scannedCount, 6)
        XCTAssertNotNil(checkpoint.completedAt)
    }

    @MainActor
    func testDuplicateIdentityLargerThanPageIsDurablyBlocked() async throws {
        let stores = try makeStores()
        let context = stores.user.mainContext
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 0..<3 {
            portable("https://same.example/feed.xml", date: date, updatedAt: date, context: context)
        }
        try context.save()
        let result = await StoreSplitSubscriptionReconciliationDryRun.runPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user,
            cacheContainer: stores.cache, pageSize: 2
        )
        XCTAssertEqual(result.status, .blockedDuplicateIdentity)
        XCTAssertNil(result.progress.lastID)
        XCTAssertEqual(result.progress.scanned, 0)
        let checkpointID = StoreSplitSubscriptionReconciliationDryRun.checkpointID
        let checkpoint = try XCTUnwrap(ModelContext(stores.cache).fetch(
            FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == checkpointID })
        ).first)
        XCTAssertEqual(checkpoint.failedCount, 1)
        XCTAssertNil(checkpoint.completedAt)
        XCTAssertEqual(try ModelContext(stores.user).fetchCount(FetchDescriptor<SubscriptionSync>()), 3)
    }

    @MainActor
    func testCancelledRestartRescansEarlierDelayedImport() async throws {
        let stores = try makeStores()
        let context = stores.user.mainContext
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        portable("https://z.example/feed.xml", date: date, updatedAt: date, context: context)
        try context.save()
        let first = await StoreSplitSubscriptionReconciliationDryRun.runPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user, cacheContainer: stores.cache
        )
        XCTAssertEqual(first.status, .traversalCompleted)
        portable("https://a.example/feed.xml", date: date, updatedAt: date, context: context)
        try context.save()
        let gate = SubscriptionReconciliationOnceGate()
        let interrupted = await StoreSplitSubscriptionReconciliationDryRun.runPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user,
            cacheContainer: stores.cache, restart: true, shouldContinue: { gate.shouldContinue() }
        )
        XCTAssertEqual(interrupted.status, .cancelled)
        let resumed = await StoreSplitSubscriptionReconciliationDryRun.runPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user, cacheContainer: stores.cache
        )
        XCTAssertEqual(resumed.status, .traversalCompleted)
        XCTAssertEqual(resumed.progress.scanned, 2)
        XCTAssertEqual(resumed.progress.unresolvedLineage, 2)
    }

    @MainActor
    func testInvalidIdentityAndMalformedCheckpointFailConservatively() async throws {
        let stores = try makeStores()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let user = stores.user.mainContext
        let invalid = SubscriptionSync(feedURL: "https://example.com/feed.xml", subscribedAt: date, updatedAt: date)
        invalid.id = "https://different.example/feed.xml"
        user.insert(invalid)
        try user.save()
        let result = await StoreSplitSubscriptionReconciliationDryRun.runPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user, cacheContainer: stores.cache
        )
        XCTAssertEqual(result.status, .traversalCompleted)
        XCTAssertEqual(result.progress.unresolvedLineage, 1)
        let checkpointID = StoreSplitSubscriptionReconciliationDryRun.checkpointID
        let cache = stores.cache.mainContext
        let checkpoint = try XCTUnwrap(cache.fetch(
            FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == checkpointID })
        ).first)
        checkpoint.cursor = "invalid"
        try cache.save()
        let corrupt = await StoreSplitSubscriptionReconciliationDryRun.runPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user, cacheContainer: stores.cache
        )
        XCTAssertEqual(corrupt.status, .failed)
        XCTAssertEqual(corrupt.error, "checkpoint_invalid")
    }
}
