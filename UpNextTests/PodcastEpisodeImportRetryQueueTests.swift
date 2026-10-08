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
}
