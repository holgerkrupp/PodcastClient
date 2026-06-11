import XCTest
@testable import UpNext

final class ListeningSummarySyncTests: XCTestCase {
    func testAggregationKeyIgnoresSourceDevice() {
        let baseDate = Date(timeIntervalSince1970: 1_000)
        let left = ListeningSummarySync(
            feedURL: "feed-a",
            periodKind: PlaySessionSummaryPeriod.week.rawValue,
            periodStart: baseDate,
            sourceDeviceID: "device-a",
            totalSeconds: 120
        )
        let right = ListeningSummarySync(
            feedURL: "feed-a",
            periodKind: PlaySessionSummaryPeriod.week.rawValue,
            periodStart: baseDate,
            sourceDeviceID: "device-b",
            totalSeconds: 180
        )

        XCTAssertEqual(left.aggregationKey, right.aggregationKey)
        XCTAssertNotEqual(left.id, right.id)
    }

    func testStableIDIncludesSourceDeviceToPreventLocalDuplicates() {
        let baseDate = Date(timeIntervalSince1970: 1_000)
        let first = ListeningSummarySync(
            feedURL: "feed-a",
            periodKind: PlaySessionSummaryPeriod.week.rawValue,
            periodStart: baseDate,
            sourceDeviceID: "device-a"
        )
        let duplicate = ListeningSummarySync(
            feedURL: "feed-a",
            periodKind: PlaySessionSummaryPeriod.week.rawValue,
            periodStart: baseDate,
            sourceDeviceID: "device-a"
        )

        XCTAssertEqual(first.id, duplicate.id)
    }
}
