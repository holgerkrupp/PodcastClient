import Foundation
import SwiftData
import XCTest
@testable import UpNext

private final class HistoryKeysetTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    init(_ remaining: Int) { self.remaining = remaining }
    func shouldContinue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

final class StoreSplitHistoryKeysetVerificationTests: XCTestCase {
    private struct Stores {
        let legacy: ModelContainer
        let userState: ModelContainer
        let cache: ModelContainer
        let episode: Episode
    }

    @MainActor
    private func makeStores() throws -> Stores {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let cache = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        let podcast = Podcast(feed: URL(string: "https://example.com/history.xml")!)
        podcast.title = "Example"
        let episode = Episode(guid: "episode", title: "Example episode", url: URL(string: "https://example.com/audio.mp3")!, podcast: podcast)
        legacy.mainContext.insert(podcast)
        legacy.mainContext.insert(episode)
        let cacheContext = ModelContext(cache)
        for phase in StoreSplitMigrationService.slicePhaseOrder where phase != StoreSplitMigrationService.Phase.listeningHistoryVerification {
            cacheContext.insert(StoreSplitMigrationCheckpoint(id: StoreSplitMigrationService.checkpointID(for: phase), migrationVersion: StoreSplitMigrationService.migrationVersion, phase: phase, cursor: "0", completedAt: .now))
        }
        try cacheContext.save()
        return Stores(legacy: legacy, userState: userState, cache: cache, episode: episode)
    }

    private func id(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!
    }

    @MainActor
    private func insertSession(_ index: Int, id: UUID?, stores: Stores, addDestination: Bool = true) {
        let start = Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 1000))
        let end = start.addingTimeInterval(120)
        let session = PlaySession(id: id, episode: stores.episode, sourceDeviceID: "fixture-device", sourceDeviceName: "Fixture", startTime: start, endTime: end, startPosition: 0, endPosition: 120, endedCleanly: true)
        stores.legacy.mainContext.insert(session)
        guard addDestination else { return }
        let identity = stores.episode.stableEpisodeIdentity
        let key = ListeningHistoryIdentity.make(feedURL: identity.feedURL, episodeID: identity.episodeID, startedAt: start, endedAt: end, startPosition: 0, endPosition: 120)
        stores.userState.mainContext.insert(ListeningHistorySync(
            id: key, feedURL: identity.feedURL, episodeID: identity.episodeID,
            podcastName: session.podcastName ?? stores.episode.displayPodcastTitle,
            episodeTitle: stores.episode.title, sourceDeviceID: "fixture-device", sourceDeviceName: "Fixture",
            startedAt: start, endedAt: end, startPosition: 0, endPosition: 120,
            listenedSeconds: 120, endedCleanly: true, isLegacyMigrated: true, updatedAt: end
        ))
    }

    @MainActor
    func testLostBoundaryNeverFallsBackToOffset() async throws {
        let stores = try makeStores()
        for index in 0..<41 { insertSession(index, id: id(index), stores: stores) }
        try stores.legacy.mainContext.save()
        try stores.userState.mainContext.save()
        let first = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
        XCTAssertEqual(first.status, .advanced)
        XCTAssertEqual(first.processed, 40)
        let checkpointID = StoreSplitMigrationService.checkpointID(for: StoreSplitMigrationService.Phase.listeningHistoryVerification)
        let checkpoint = try XCTUnwrap(ModelContext(stores.cache).fetch(FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == checkpointID })).first)
        let cursorBefore = try XCTUnwrap(checkpoint.cursor)
        let updatedAtBefore = checkpoint.updatedAt
        let scannedBefore = checkpoint.scannedCount
        let failedBefore = checkpoint.failedCount
        XCTAssertLessThan(try XCTUnwrap(cursorBefore.range(of: "\"afterID\"")).lowerBound,
                          try XCTUnwrap(cursorBefore.range(of: "\"scanned\"")).lowerBound)
        XCTAssertLessThan(try XCTUnwrap(cursorBefore.range(of: "\"scanned\"")).lowerBound,
                          try XCTUnwrap(cursorBefore.range(of: "\"sourceCount\"")).lowerBound)
        let boundaryID = id(39)
        let boundary = try XCTUnwrap(stores.legacy.mainContext.fetch(FetchDescriptor<PlaySession>(predicate: #Predicate { $0.id == boundaryID })).first)
        stores.legacy.mainContext.delete(boundary)
        try stores.legacy.mainContext.save()
        for _ in 0..<2 {
            let report = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
            XCTAssertEqual(report.status, .failed)
            XCTAssertEqual(report.error, "listening_history_verification_source_boundary_lost")
            let current = try XCTUnwrap(ModelContext(stores.cache).fetch(FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == checkpointID })).first)
            XCTAssertEqual(current.cursor, cursorBefore)
            XCTAssertEqual(current.updatedAt, updatedAtBefore)
            XCTAssertEqual(current.scannedCount, scannedBefore)
            XCTAssertEqual(current.failedCount, failedBefore)
            XCTAssertNil(current.completedAt)
        }
    }

    @MainActor
    func testNilAndDuplicateSourceIDsFailClosed() async throws {
        for duplicate in [false, true] {
            let stores = try makeStores()
            let sourceID = duplicate ? id(0) : nil
            insertSession(0, id: sourceID, stores: stores, addDestination: false)
            if duplicate { insertSession(1, id: sourceID, stores: stores, addDestination: false) }
            try stores.legacy.mainContext.save()
            let report = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
            XCTAssertEqual(report.status, .failed)
            XCTAssertEqual(report.error, duplicate ? "listening_history_verification_duplicate_source_identity" : "listening_history_verification_source_identity_unresolved")
            XCTAssertEqual(report.processed, 0)
        }
    }

    @MainActor
    func testInterruptedPageDoesNotAdvanceCursor() async throws {
        let stores = try makeStores()
        for index in 0..<3 { insertSession(index, id: id(index), stores: stores) }
        try stores.legacy.mainContext.save()
        try stores.userState.mainContext.save()
        let gate = HistoryKeysetTestGate(3)
        let cancelled = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache, shouldContinue: { gate.shouldContinue() })
        XCTAssertEqual(cancelled.status, .cancelled)
        let checkpointID = StoreSplitMigrationService.checkpointID(for: StoreSplitMigrationService.Phase.listeningHistoryVerification)
        XCTAssertTrue(try ModelContext(stores.cache).fetch(FetchDescriptor<StoreSplitMigrationCheckpoint>(predicate: #Predicate { $0.id == checkpointID })).isEmpty)
        let retried = await StoreSplitMigrationService.runSlice(legacyContainer: stores.legacy, userStateContainer: stores.userState, cacheContainer: stores.cache)
        XCTAssertEqual(retried.status, .completed)
        XCTAssertEqual(retried.processed, 3)
    }
}
