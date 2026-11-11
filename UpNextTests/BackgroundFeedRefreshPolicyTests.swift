import XCTest
@testable import UpNext

final class BackgroundFeedRefreshPolicyTests: XCTestCase {
    func testBackgroundCandidatePoolsAndConcurrencyStayBounded() {
        let appRefresh = SubscriptionManager.BackgroundFeedRefreshPolicy.forReason(.appRefresh)
        let processing = SubscriptionManager.BackgroundFeedRefreshPolicy.forReason(.processing)
        let foreground = SubscriptionManager.BackgroundFeedRefreshPolicy.forReason(.foregroundQuiet)

        XCTAssertEqual(appRefresh.maxPodcastsPerRun, 20)
        XCTAssertEqual(processing.maxPodcastsPerRun, 20)
        XCTAssertEqual(appRefresh.maxConcurrentPodcastUpdates, 2)
        XCTAssertEqual(processing.maxConcurrentPodcastUpdates, 2)
        XCTAssertEqual(foreground.maxConcurrentPodcastUpdates, 1)
        XCTAssertLessThanOrEqual(foreground.maxPodcastsPerRun, 10)
        XCTAssertLessThanOrEqual(processing.maxConcurrentPodcastUpdates, 2)
    }
}
