import Foundation
import XCTest
@testable import UpNext

final class BackgroundFeedRefreshStateStoreTests: XCTestCase {
    func testAttemptAndSuccessfulCheckRemainDistinctAcrossTenFiftyAndHundredFeeds() async throws {
        for count in [10, 50, 100] {
            let suiteName = "BackgroundFeedRefreshStateStoreTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let key = "state"
            let store = BackgroundFeedRefreshStateStore(suiteName: suiteName, key: key)
            let feeds = try (0..<count).map { index in
                try XCTUnwrap(URL(string: "https://example.invalid/podcast/\(index).xml"))
            }
            let now = Date()

            for (index, feed) in feeds.enumerated() {
                let attempt = now.addingTimeInterval(TimeInterval(-index))
                await store.recordAttempt(for: feed, at: attempt)
                if index.isMultiple(of: 3) {
                    await store.recordSuccessfulCheck(for: feed, at: attempt)
                }
            }

            let restoredStore = BackgroundFeedRefreshStateStore(suiteName: suiteName, key: key)
            let pending = await restoredStore.pendingWorkSummary(at: now)
            XCTAssertEqual(pending.feedCount, count)
            XCTAssertEqual(pending.pendingCount, count - (count + 2) / 3)

            let firstFeed = try XCTUnwrap(feeds.first)
            let firstStateValue = await restoredStore.state(for: firstFeed)
            let firstState = try XCTUnwrap(firstStateValue)
            XCTAssertNotNil(firstState.lastAttempt)
            XCTAssertNotNil(firstState.lastSuccessfulCheck)

            let secondFeed = try XCTUnwrap(feeds.dropFirst().first)
            let secondStateValue = await restoredStore.state(for: secondFeed)
            let secondState = try XCTUnwrap(secondStateValue)
            XCTAssertNotNil(secondState.lastAttempt)
            XCTAssertNil(secondState.lastSuccessfulCheck)
        }
    }
}
