import Foundation
import SwiftData
import XCTest
@testable import UpNext

private final class ReconciliationOnceGate: @unchecked Sendable {
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

final class StoreSplitPlaylistReconciliationDryRunTests: XCTestCase {
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
    private func makePlaylist(id: String, title: String, context: ModelContext) -> Playlist {
        let playlist = Playlist()
        playlist.syncID = id
        playlist.title = title
        playlist.symbolName = "star"
        playlist.sortIndex = 3
        context.insert(playlist)
        return playlist
    }

    @MainActor
    private func makePortable(
        id: String,
        title: String,
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        context: ModelContext
    ) -> PlaylistSync {
        let playlist = PlaylistSync(
            id: id,
            title: title,
            symbolName: "star",
            sortIndex: 3,
            kindRawValue: Playlist.Kind.manual.rawValue,
            isDeleted: isDeleted,
            deletedAt: deletedAt
        )
        context.insert(playlist)
        return playlist
    }

    @MainActor
    func testPagedDryRunClassifiesConflictsAndPreservesDestinationRows() async throws {
        let stores = try makeStores()
        let legacy = stores.legacy.mainContext
        let user = stores.user.mainContext
        makePlaylist(id: "a", title: "Same", context: legacy)
        makePlaylist(id: "b", title: "Local", context: legacy)
        makePortable(id: "a", title: "Same", context: user)
        makePortable(id: "b", title: "Remote", context: user)
        makePortable(id: "c", title: "Other device", context: user)
        makePortable(id: "d", title: "Deleted", isDeleted: true, deletedAt: .now, context: user)
        makePortable(id: "e", title: "Bad tombstone", isDeleted: true, context: user)
        try legacy.save()
        try user.save()

        let first = await StoreSplitReconciliationDryRun.runPlaylistPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user,
            cacheContainer: stores.cache, pageSize: 2
        )
        XCTAssertEqual(first.status, .advanced)
        XCTAssertEqual(first.progress.scanned, 2)
        XCTAssertEqual(first.progress.matching, 1)
        XCTAssertEqual(first.progress.semanticConflicts, 1)

        let second = await StoreSplitReconciliationDryRun.runPlaylistPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user,
            cacheContainer: stores.cache, pageSize: 2
        )
        XCTAssertEqual(second.status, .advanced)
        XCTAssertEqual(second.progress.unresolvedLineage, 1)
        XCTAssertEqual(second.progress.tombstonesPreserved, 1)

        let third = await StoreSplitReconciliationDryRun.runPlaylistPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user,
            cacheContainer: stores.cache, pageSize: 2
        )
        XCTAssertEqual(third.status, .traversalCompleted)
        XCTAssertEqual(third.progress.scanned, 5)
        XCTAssertEqual(third.progress.inconsistentTombstones, 1)
        XCTAssertEqual(try ModelContext(stores.user).fetchCount(FetchDescriptor<PlaylistSync>()), 5)
        let checkpointID = StoreSplitReconciliationDryRun.checkpointID
        let checkpoint = try XCTUnwrap(ModelContext(stores.cache).fetch(
            FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == checkpointID })
        ).first)
        XCTAssertEqual(checkpoint.scannedCount, 5)
        XCTAssertNotNil(checkpoint.completedAt)
    }

    @MainActor
    func testRestartAfterDelayedImportIncludesEarlierIdentity() async throws {
        let stores = try makeStores()
        let user = stores.user.mainContext
        makePortable(id: "z", title: "First import", context: user)
        try user.save()
        let first = await StoreSplitReconciliationDryRun.runPlaylistPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user,
            cacheContainer: stores.cache, pageSize: 1
        )
        XCTAssertEqual(first.status, .traversalCompleted)
        makePortable(id: "a", title: "Delayed import", context: user)
        try user.save()

        let restart = await StoreSplitReconciliationDryRun.runPlaylistPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user,
            cacheContainer: stores.cache, pageSize: 1, restart: true
        )
        XCTAssertEqual(restart.status, .advanced)
        XCTAssertEqual(restart.progress.lastID, "a")
        XCTAssertEqual(restart.progress.scanned, 1)
        let finish = await StoreSplitReconciliationDryRun.runPlaylistPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user,
            cacheContainer: stores.cache, pageSize: 1
        )
        XCTAssertEqual(finish.status, .traversalCompleted)
        XCTAssertEqual(finish.progress.scanned, 2)
        XCTAssertEqual(finish.progress.unresolvedLineage, 2)
        XCTAssertEqual(try ModelContext(stores.user).fetchCount(FetchDescriptor<PlaylistSync>()), 2)
    }

    @MainActor
    func testDuplicateIdentityLargerThanPageBlocksWithoutAdvancing() async throws {
        let stores = try makeStores()
        let user = stores.user.mainContext
        for _ in 0..<3 { makePortable(id: "duplicate", title: "Same", context: user) }
        try user.save()
        let result = await StoreSplitReconciliationDryRun.runPlaylistPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user,
            cacheContainer: stores.cache, pageSize: 2
        )
        XCTAssertEqual(result.status, .blockedDuplicateIdentity)
        XCTAssertEqual(result.error, "duplicate_identity_exceeds_page_budget")
        XCTAssertNil(result.progress.lastID)
        XCTAssertEqual(result.progress.scanned, 0)
        let checkpointID = StoreSplitReconciliationDryRun.checkpointID
        let checkpoint = try XCTUnwrap(ModelContext(stores.cache).fetch(
            FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == checkpointID })
        ).first)
        XCTAssertEqual(checkpoint.failedCount, 1)
        XCTAssertNil(checkpoint.completedAt)
        XCTAssertEqual(try ModelContext(stores.user).fetchCount(FetchDescriptor<PlaylistSync>()), 3)
    }

    @MainActor
    func testCancellationLeavesCommittedCursorUnchanged() async throws {
        let stores = try makeStores()
        let user = stores.user.mainContext
        makePortable(id: "a", title: "One", context: user)
        makePortable(id: "b", title: "Two", context: user)
        try user.save()
        let first = await StoreSplitReconciliationDryRun.runPlaylistPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user,
            cacheContainer: stores.cache, pageSize: 1
        )
        let cancelled = await StoreSplitReconciliationDryRun.runPlaylistPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user,
            cacheContainer: stores.cache, pageSize: 1, shouldContinue: { false }
        )
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(cancelled.progress, first.progress)
        let resumed = await StoreSplitReconciliationDryRun.runPlaylistPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user,
            cacheContainer: stores.cache, pageSize: 1
        )
        XCTAssertEqual(resumed.status, .traversalCompleted)
        XCTAssertEqual(resumed.progress.scanned, 2)
    }

    @MainActor
    func testInterruptedRestartInvalidatesOldCompletedTraversal() async throws {
        let stores = try makeStores()
        let user = stores.user.mainContext
        makePortable(id: "z", title: "Original", context: user)
        try user.save()
        let first = await StoreSplitReconciliationDryRun.runPlaylistPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user,
            cacheContainer: stores.cache
        )
        XCTAssertEqual(first.status, .traversalCompleted)
        makePortable(id: "a", title: "Delayed", context: user)
        try user.save()

        let gate = ReconciliationOnceGate()
        let interrupted = await StoreSplitReconciliationDryRun.runPlaylistPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user,
            cacheContainer: stores.cache, restart: true,
            shouldContinue: { gate.shouldContinue() }
        )
        XCTAssertEqual(interrupted.status, .cancelled)
        let resumed = await StoreSplitReconciliationDryRun.runPlaylistPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user,
            cacheContainer: stores.cache
        )
        XCTAssertEqual(resumed.status, .traversalCompleted)
        XCTAssertEqual(resumed.progress.scanned, 2)
    }

    @MainActor
    func testCorruptCheckpointIsAnErrorRatherThanACompletedScan() async throws {
        let stores = try makeStores()
        let cache = stores.cache.mainContext
        cache.insert(StoreSplitMigrationCheckpoint(
            id: StoreSplitReconciliationDryRun.checkpointID,
            migrationVersion: StoreSplitMigrationService.migrationVersion,
            phase: StoreSplitReconciliationDryRun.checkpointPhase,
            cursor: "invalid"
        ))
        try cache.save()
        let result = await StoreSplitReconciliationDryRun.runPlaylistPage(
            legacyContainer: stores.legacy, userStateContainer: stores.user,
            cacheContainer: stores.cache
        )
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.error, "checkpoint_invalid")
    }
}
