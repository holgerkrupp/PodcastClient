import Foundation
import SwiftData
import XCTest
@testable import UpNext

final class StoreSplitPortableWriteSafetyTests: XCTestCase {
    private enum FixtureError: Error { case failed }

    @MainActor
    func testPortableWriteFailureWarningSurvivesMonitorRecreation() throws {
        let suite = "PortableWriteFailureMonitorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PortableWriteFailureMonitor(defaults: defaults)
        let second = PortableWriteFailureMonitor(defaults: defaults)
        XCTAssertFalse(first.needsRecovery)
        first.reportFailure()
        second.refresh()
        XCTAssertTrue(second.needsRecovery)
        XCTAssertTrue(PortableWriteFailureMonitor(defaults: defaults).needsRecovery)
    }

    private func state(_ id: String, position: Double = 10) -> StoreSplitEpisodeStateSnapshot {
        StoreSplitEpisodeStateSnapshot(
            identity: EpisodeStableIdentity(feedURL: "https://example.com/feed", episodeID: "guid:\(id)"),
            playPosition: position, maxPlayPosition: position, duration: 100,
            isPlayed: false, isArchived: false, wasSkipped: false,
            completedAt: nil, archivedAt: nil, firstPlayedAt: nil, lastPlayedAt: nil
        )
    }

    private func history() -> StoreSplitListeningHistorySnapshot {
        StoreSplitListeningHistorySnapshot(
            id: "history", identity: state("history").identity,
            podcastName: "Podcast", episodeTitle: "Episode", sourceDeviceID: "device",
            sourceDeviceName: nil, deviceModel: nil,
            startedAt: Date(timeIntervalSince1970: 10), endedAt: Date(timeIntervalSince1970: 20),
            startPosition: 0, endPosition: 10, listenedSeconds: 10,
            silenceGapTimeSavedSeconds: 0, playbackRateTimeSavedSeconds: 0, endedCleanly: true
        )
    }

    @MainActor
    func testFetchAndSaveFailuresPropagateAndRollbackBeforeRetry() async throws {
        let container = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let stateWriter = StoreSplitEpisodeStateSyncWriter(modelContainer: container)
        let fetchFailure = StoreSplitEpisodeStateWriterIO(fetch: { _, _ in throw FixtureError.failed })
        do {
            _ = try await stateWriter.upsert(state("one"), io: fetchFailure)
            XCTFail("Expected the source fetch to fail")
        } catch FixtureError.failed { }
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<EpisodeStateSync>()), 0)

        let saveFailure = StoreSplitEpisodeStateWriterIO(save: { _ in throw FixtureError.failed })
        do {
            _ = try await stateWriter.upsert(state("one"), io: saveFailure)
            XCTFail("Expected the destination save to fail")
        } catch FixtureError.failed { }
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<EpisodeStateSync>()), 0)
        let succeeded = try await stateWriter.upsert(state("one"))
        XCTAssertTrue(succeeded)

        let historyWriter = StoreSplitListeningHistorySyncWriter(modelContainer: container)
        let historyFetchFailure = StoreSplitListeningHistoryWriterIO(fetch: { _, _ in throw FixtureError.failed })
        do {
            try await historyWriter.upsert(history(), io: historyFetchFailure)
            XCTFail("Expected the history fetch to fail")
        } catch FixtureError.failed { }
        let historyFailure = StoreSplitListeningHistoryWriterIO(save: { _ in throw FixtureError.failed })
        do {
            try await historyWriter.upsert(history(), io: historyFailure)
            XCTFail("Expected the history save to fail")
        } catch FixtureError.failed { }
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<ListeningHistorySync>()), 0)
        try await historyWriter.upsert(history())
        try await historyWriter.upsert(history())
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<ListeningHistorySync>()), 1)
    }

    @MainActor
    func testOlderBookmarkWriteDoesNotReplaceNewerDestination() async throws {
        let container = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let identity = state("bookmark").identity
        let newest = Date(timeIntervalSince1970: 200)
        container.mainContext.insert(BookmarkSync(
            id: "bookmark", feedURL: identity.feedURL, episodeID: identity.episodeID,
            time: 50, title: "Newer", isDeleted: true, deletedAt: newest, updatedAt: newest
        ))
        try container.mainContext.save()
        let writer = StoreSplitBookmarkSyncWriter(modelContainer: container)
        let snapshot = StoreSplitBookmarkSnapshot(
            id: "bookmark", identity: identity, time: 10, title: "Older",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        try await writer.upsert(snapshot, at: Date(timeIntervalSince1970: 100))
        let row = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<BookmarkSync>()).first)
        XCTAssertEqual(row.title, "Newer")
        XCTAssertEqual(row.deletedAt, newest)
        let fetchFailure = StoreSplitBookmarkWriterIO(fetch: { _, _ in throw FixtureError.failed })
        do {
            try await writer.tombstone(snapshot, io: fetchFailure)
            XCTFail("Expected the bookmark fetch to fail")
        } catch FixtureError.failed { }
        let newBookmark = StoreSplitBookmarkSnapshot(
            id: "new", identity: identity, time: 10, title: "New", createdAt: .now
        )
        let saveFailure = StoreSplitBookmarkWriterIO(save: { _ in throw FixtureError.failed })
        do {
            try await writer.upsert(newBookmark, io: saveFailure)
            XCTFail("Expected the bookmark save to fail")
        } catch FixtureError.failed { }
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<BookmarkSync>()), 1)
        try await writer.upsert(newBookmark)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<BookmarkSync>()), 2)
    }

    @MainActor
    func testConcurrentEnqueuesSurviveRestartAndAcknowledgeInBoundedBatches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = StoreSplitPortableWriteOutbox(directoryURL: directory)
        let second = StoreSplitPortableWriteOutbox(directoryURL: directory)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                let snapshot = state("\(index)")
                group.addTask {
                    try await (index.isMultiple(of: 2) ? first : second)
                        .enqueue(.episodeState(snapshot, date), now: date)
                }
            }
            try await group.waitForAll()
        }
        let reopened = StoreSplitPortableWriteOutbox(directoryURL: directory)
        let container = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let firstPass = try await reopened.drain(userStateContainer: container, limit: 2, now: date)
        XCTAssertEqual(firstPass.succeeded, 2)
        XCTAssertTrue(firstPass.hasPending)
        let secondPass = try await reopened.drain(userStateContainer: container, now: date)
        XCTAssertEqual(secondPass.succeeded, 6)
        XCTAssertFalse(secondPass.hasPending)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<EpisodeStateSync>()), 8)
    }

    @MainActor
    func testFullOutboxDurablyReplacesOlderEpisodeState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Future-dated entries fill the queue without making this test perform
        // hundreds of synchronous writes through the production enqueue path.
        for index in 0..<511 {
            let name = String(format: "%020lld-other-%020lld-%@.json", Int64(1_800_000_000_000), Int64(0), UUID().uuidString)
            try Data("fixture \(index)".utf8).write(to: directory.appendingPathComponent(name))
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let outbox = StoreSplitPortableWriteOutbox(directoryURL: directory)
        try await outbox.enqueue(.episodeState(state("same", position: 10), date), now: date)
        let originalURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" && !$0.lastPathComponent.contains("-other-") })
        let originalData = try Data(contentsOf: originalURL)
        do {
            try await outbox.enqueue(.episodeState(state("different"), date), now: date)
            XCTFail("An unrelated entry must fail when the queue is full")
        } catch StoreSplitPortableWriteOutbox.OutboxError.full { }

        let newer = date.addingTimeInterval(10)
        try await outbox.enqueue(.episodeState(state("same", position: 90), newer), now: date)
        // Simulate a crash after the new durable write and before old removal.
        try originalData.write(to: originalURL)
        let reopened = StoreSplitPortableWriteOutbox(directoryURL: directory)
        let container = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let result = try await reopened.drain(userStateContainer: container, limit: 2, now: date)
        XCTAssertEqual(result.succeeded, 2)
        XCTAssertTrue(result.hasPending)
        let saved = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<EpisodeStateSync>()).first)
        XCTAssertEqual(saved.playPosition, 90)
        XCTAssertEqual(saved.updatedAt, newer)
    }

    @MainActor
    func testFailedRetriesArePostponedAtCrashRecoveryCapacity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let outbox = StoreSplitPortableWriteOutbox(directoryURL: directory)
        let snapshot = StoreSplitBookmarkSnapshot(
            id: UUID().uuidString, identity: state("bookmark").identity,
            time: 10, title: "Bookmark", createdAt: date
        )
        try await outbox.enqueue(.bookmarkDeletionAfterLocalCommit(snapshot, date), now: date)
        try await outbox.enqueue(.bookmarkDeletionAfterLocalCommit(snapshot, date), now: date)
        for _ in 0..<511 {
            let name = String(format: "%020lld-other-%020lld-%@.json", Int64(1_800_000_000_000), Int64(0), UUID().uuidString)
            try Data("fixture".utf8).write(to: directory.appendingPathComponent(name))
        }
        let container = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        // No durable legacy container is supplied, so neither tombstone may
        // be published; both intents must remain and be scheduled for later.
        let result = try await outbox.drain(userStateContainer: container, limit: 2, now: date)
        XCTAssertEqual(result.failed, 2)
        XCTAssertTrue(result.hasPending)
        XCTAssertEqual(StoreSplitPortableWriteOutbox.earliestDueOnDisk(directoryURL: directory), date.addingTimeInterval(30))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 513)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<BookmarkSync>()), 0)
    }

    @MainActor
    func testNewerQueuedStateSurvivesAnOlderRetryAndCancelledDrain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = StoreSplitPortableWriteOutbox(directoryURL: directory)
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = older.addingTimeInterval(10)
        try await outbox.enqueue(.episodeState(state("same", position: 90), newer), now: older)
        try await outbox.enqueue(.episodeState(state("same", position: 10), older), now: older)
        let container = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let cancelled = try await outbox.drain(userStateContainer: container, now: older, shouldContinue: { false })
        XCTAssertTrue(cancelled.hasPending)
        XCTAssertEqual(cancelled.attempted, 0)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<EpisodeStateSync>()), 0)
        let result = try await outbox.drain(userStateContainer: container, now: older)
        XCTAssertEqual(result.succeeded, 2)
        XCTAssertFalse(result.hasPending)
        let state = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<EpisodeStateSync>()).first)
        XCTAssertEqual(state.playPosition, 90)
        XCTAssertEqual(state.updatedAt, newer)
    }

    @MainActor
    func testBookmarkTombstoneWaitsForDurableLocalDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = StoreSplitPortableWriteOutbox(directoryURL: directory)
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let podcast = Podcast(feed: URL(string: "https://example.com/bookmark")!)
        let episode = Episode(guid: "episode", title: "Episode", url: URL(string: "https://example.com/audio.mp3")!, podcast: podcast)
        let uuid = UUID()
        let bookmark = Bookmark(start: 10, title: "Bookmark", type: .bookmark)
        bookmark.uuid = uuid
        bookmark.bookmarkEpisode = episode
        legacy.mainContext.insert(podcast)
        legacy.mainContext.insert(episode)
        legacy.mainContext.insert(bookmark)
        try legacy.mainContext.save()
        let identity = episode.stableEpisodeIdentity
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = StoreSplitBookmarkSnapshot(id: uuid.uuidString, identity: identity, time: 10, title: "Bookmark", createdAt: date)
        userState.mainContext.insert(BookmarkSync(id: uuid.uuidString, feedURL: identity.feedURL, episodeID: identity.episodeID, time: 10, updatedAt: date.addingTimeInterval(-1)))
        try userState.mainContext.save()
        try await outbox.enqueue(.bookmarkDeletionAfterLocalCommit(snapshot, date), now: date)

        let blocked = try await outbox.drain(userStateContainer: userState, legacyContainer: legacy, now: date)
        XCTAssertEqual(blocked.failed, 1)
        XCTAssertTrue(blocked.hasPending)
        XCTAssertNil(try ModelContext(userState).fetch(FetchDescriptor<BookmarkSync>()).first?.deletedAt)

        legacy.mainContext.delete(bookmark)
        try legacy.mainContext.save()
        let retried = try await outbox.drain(userStateContainer: userState, legacyContainer: legacy, now: date.addingTimeInterval(31))
        XCTAssertEqual(retried.succeeded, 1)
        XCTAssertFalse(retried.hasPending)
        XCTAssertEqual(try ModelContext(userState).fetch(FetchDescriptor<BookmarkSync>()).first?.deletedAt, date)
    }
}
