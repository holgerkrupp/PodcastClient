import Foundation
import XCTest
@testable import UpNext

final class PodcastEpisodeImportRetryQueueTests: XCTestCase {
    func testFailureClassificationSeparatesAuthenticationPermanentAndTransient() {
        XCTAssertEqual(
            PodcastEpisodeImportRetryQueue.disposition(for: PodcastParserError.couldNotLoad(
                URL(string: "https://example.com/feed.xml")!,
                statusCode: 429
            )),
            .retryable
        )
        XCTAssertEqual(
            PodcastEpisodeImportRetryQueue.disposition(for: PodcastParserError.couldNotLoad(
                URL(string: "https://example.com/feed.xml")!,
                statusCode: 403
            )),
            .authentication
        )
        XCTAssertEqual(
            PodcastEpisodeImportRetryQueue.disposition(for: PodcastParserError.notAPodcastFeed),
            .permanent
        )
        XCTAssertEqual(
            PodcastEpisodeImportRetryQueue.disposition(for: CancellationError()),
            .cancelled
        )
    }

    func testBackoffGrowsExponentiallyAndHasACap() {
        XCTAssertEqual(PodcastEpisodeImportRetryQueue.backoffSeconds(attempt: 1), 30)
        XCTAssertEqual(PodcastEpisodeImportRetryQueue.backoffSeconds(attempt: 2), 60)
        XCTAssertEqual(PodcastEpisodeImportRetryQueue.backoffSeconds(attempt: 3), 120)
        XCTAssertEqual(PodcastEpisodeImportRetryQueue.backoffSeconds(attempt: 12), 6 * 60 * 60)
    }

    func testPagedCheckpointSurvivesQueueRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PodcastRetryQueueTests/\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appending(path: "retries.json")
        let feed = URL(string: "https://example.com/feed.xml")!
        let continuation = URL(string: "https://example.com/feed.xml?page=2&token=secret-value")!
        let safeContinuation = URL(string: "https://example.com/feed.xml?page=2")!

        await PodcastEpisodeImportRetryQueue(storageURL: storage)
            .checkpoint(feedURL: feed, resumeURL: continuation)
        let restored = PodcastEpisodeImportRetryQueue(storageURL: storage)
        let savedURL = await restored.pendingResumeURL(for: feed)
        XCTAssertEqual(savedURL, safeContinuation)
        XCTAssertFalse(try String(contentsOf: storage, encoding: .utf8).contains("secret-value"))

        await restored.remove(feedURL: feed)
        let afterRemoval = await PodcastEpisodeImportRetryQueue(storageURL: storage)
            .pendingResumeURL(for: feed)
        XCTAssertNil(afterRemoval)
    }
}
