import Foundation
import XCTest
@testable import UpNext

/// Lifetime checks for issue #433: prepared-feed spool files, writer-gate
/// waiters and shared refresh flights must not outlive their operation.
final class PodcastRefreshLifetimeTests: XCTestCase {
    private static func largeParsedFeed() -> [String: Any] {
        [
            "description": String(repeating: "a", count: 7 * 1024 * 1024),
            "episodes": [["title": "Episode", "guid": "spool-0"] as [String: Any]]
        ]
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PodcastRefreshLifetimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    // MARK: Spool files

    func testSpoolFileIsRemovedWhenPreparedFeedIsReleasedAfterSuccess() throws {
        var spoolURL: URL?
        do {
            let prepared = try PreparedPodcastFeed(Self.largeParsedFeed())
            spoolURL = prepared.spoolFileURL
            let url = try XCTUnwrap(spoolURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let imported = try prepared.importDictionary
            XCTAssertEqual((imported["episodes"] as? [[String: Any]])?.count, 1)
        }
        let url = try XCTUnwrap(spoolURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSpoolFileIsRemovedWhenOperationThrows() async throws {
        struct Failure: Error {}
        final class URLBox: @unchecked Sendable { var url: URL? }
        let box = URLBox()
        let task = Task {
            let prepared = try PreparedPodcastFeed(Self.largeParsedFeed())
            box.url = prepared.spoolFileURL
            _ = try prepared.importDictionary
            throw Failure()
        }
        do {
            _ = try await task.value
            XCTFail("Expected the operation to throw")
        } catch is Failure {}
        let url = try XCTUnwrap(box.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSpoolFileIsRemovedWhenWaitingOperationIsCancelled() async throws {
        final class URLBox: @unchecked Sendable { var url: URL? }
        let box = URLBox()
        let created = expectation(description: "spool created")
        let task = Task {
            let prepared = try PreparedPodcastFeed(Self.largeParsedFeed())
            box.url = prepared.spoolFileURL
            created.fulfill()
            // Stands in for a large feed waiting for the serialized writer.
            try await Task.sleep(for: .seconds(30))
            _ = try prepared.importDictionary
        }
        await fulfillment(of: [created], timeout: 10)
        let url = try XCTUnwrap(box.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testStaleSpoolSweepRemovesOnlyOldSpoolFiles() throws {
        let directory = try temporaryDirectory()
        let fileManager = FileManager.default
        let old = directory.appending(path: "old.json")
        let fresh = directory.appending(path: "fresh.json")
        let unrelated = directory.appending(path: "old.txt")
        for file in [old, fresh, unrelated] {
            XCTAssertTrue(fileManager.createFile(atPath: file.path, contents: Data("{}".utf8)))
        }
        let now = Date()
        let twoDaysAgo = now.addingTimeInterval(-2 * 24 * 60 * 60)
        try fileManager.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: old.path)
        try fileManager.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: unrelated.path)

        let removed = PreparedPodcastFeed.removeStaleSpoolFiles(now: now, in: directory)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: old.path))
        XCTAssertTrue(fileManager.fileExists(atPath: fresh.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unrelated.path))
        XCTAssertEqual(
            PreparedPodcastFeed.removeStaleSpoolFiles(in: directory.appending(path: "missing")),
            0
        )
    }

    // MARK: Writer gate

    /// Returns true when the permit was obtained (and released again) in time.
    private func canAcquire(
        _ coordinator: PodcastFeedCommitCoordinator,
        within timeout: Duration = .seconds(2)
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await coordinator.acquire()
                    await coordinator.release()
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    func testCancelledWriterWaiterDoesNotKeepOrConsumeThePermit() async throws {
        let coordinator = PodcastFeedCommitCoordinator()
        try await coordinator.acquire()

        let waiters = (0..<5).map { _ in
            Task { try await coordinator.acquire() }
        }
        try await Task.sleep(for: .milliseconds(50))
        waiters.forEach { $0.cancel() }
        for waiter in waiters {
            do {
                try await waiter.value
                XCTFail("A cancelled queued waiter must not receive the permit")
            } catch is CancellationError {}
        }

        await coordinator.release()
        let acquired = await canAcquire(coordinator)
        XCTAssertTrue(acquired, "The writer permit is stuck after cancelled waiters")
    }

    func testWriterWaiterCancelledWhileBeingGrantedLeavesGateUsable() async throws {
        let coordinator = PodcastFeedCommitCoordinator()
        for _ in 0..<50 {
            try await coordinator.acquire()
            let waiter = Task { () -> Bool in
                do {
                    try await coordinator.acquire()
                    return true
                } catch {
                    return false
                }
            }
            await Task.yield()
            // Race the hand-off against cancellation; either side may win.
            await coordinator.release()
            waiter.cancel()
            if await waiter.value {
                await coordinator.release()
            }
            let acquired = await canAcquire(coordinator)
            XCTAssertTrue(acquired, "The writer permit is stuck after a cancelled hand-off")
            if acquired == false { return }
        }
    }

    // MARK: Shared refresh flights

    func testCancellingEveryFlightWaiterCancelsWorkAndAllowsAFreshFlight() async throws {
        actor Probe {
            var started = 0
            var cancelled = 0
            func start() { started += 1 }
            func cancel() { cancelled += 1 }
        }
        let coordinator = FeedRefreshCoordinator()
        let probe = Probe()
        let feed = URL(string: "https://example.com/cancelled-flight.xml")!
        let intent = FeedRefreshCoordinator.Intent(
            requiresGET: false,
            visible: false,
            resolvesMissingDurations: false,
            processesNewEpisodes: false,
            deadline: nil
        )
        let slowOperation: @Sendable () async throws -> PodcastUpdateSummary = {
            await probe.start()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                await probe.cancel()
                // Like a feed commit that finishes after cancellation, the
                // abandoned work takes a moment to unwind.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                        continuation.resume()
                    }
                }
                throw error
            }
            return PodcastUpdateSummary(didUpdateFeed: true, newEpisodeCount: 0)
        }

        let callers = (0..<3).map { _ in
            Task { try await coordinator.run(feedURL: feed, intent: intent, operation: slowOperation) }
        }
        try await Task.sleep(for: .milliseconds(100))
        callers.forEach { $0.cancel() }
        for caller in callers {
            do {
                _ = try await caller.value
                XCTFail("A cancelled caller must stop waiting")
            } catch is CancellationError {}
        }

        // Immediately ask again. The abandoned flight is still unwinding; the
        // new caller must not join it and inherit its cancellation.
        let result = try await coordinator.run(feedURL: feed, intent: intent) {
            await probe.start()
            return PodcastUpdateSummary(didUpdateFeed: true, newEpisodeCount: 2)
        }
        XCTAssertEqual(result.newEpisodeCount, 2)
        let cancelledOnce = await probe.cancelled
        XCTAssertEqual(cancelledOnce, 1, "Abandoned flight work must be cancelled, not left running")
        let startedAfter = await probe.started
        XCTAssertEqual(startedAfter, 2, "Concurrent callers must share one flight; the retry gets a fresh one")
    }
}
