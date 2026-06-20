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

    func testGlobalSummaryAggregationAddsDifferentDevices() {
        let baseDate = Date(timeIntervalSince1970: 1_000)
        let records = [
            ListeningSummarySync(
                feedURL: "feed-a",
                periodKind: PlaySessionSummaryPeriod.week.rawValue,
                periodStart: baseDate,
                sourceDeviceID: "device-a",
                totalSeconds: 120
            ),
            ListeningSummarySync(
                feedURL: "feed-a",
                periodKind: PlaySessionSummaryPeriod.week.rawValue,
                periodStart: baseDate,
                sourceDeviceID: "device-b",
                totalSeconds: 180
            )
        ]

        XCTAssertEqual(
            ListeningSummaryAggregation.globalStatistics(from: records).totalSeconds,
            300
        )
        XCTAssertEqual(
            ListeningSummaryAggregation.globalStatistics(
                from: records,
                sourceDeviceID: "device-a"
            ).totalSeconds,
            120
        )
    }

    func testGlobalSummaryAggregationDoesNotAddDuplicateLogicalRecords() {
        let periodStart = Date(timeIntervalSince1970: 1_000)
        let first = ListeningSummarySync(
            feedURL: "feed-a",
            periodKind: PlaySessionSummaryPeriod.week.rawValue,
            periodStart: periodStart,
            sourceDeviceID: "device-a",
            totalSeconds: 120,
            silenceGapTimeSavedSeconds: 5
        )
        let duplicate = ListeningSummarySync(
            feedURL: "feed-a",
            periodKind: PlaySessionSummaryPeriod.week.rawValue,
            periodStart: periodStart,
            sourceDeviceID: "device-a",
            totalSeconds: 180,
            silenceGapTimeSavedSeconds: 3
        )

        let statistics = ListeningSummaryAggregation.globalStatistics(
            from: [first, duplicate]
        )

        XCTAssertEqual(statistics.totalSeconds, 180)
        XCTAssertEqual(statistics.silenceGapTimeSavedSeconds, 5)
    }

    func testListeningHistoryDeduplicatesSessionIDAcrossDevices() {
        let first = ListeningHistorySync(
            id: "shared-session",
            feedURL: "feed-a",
            episodeID: "episode-a",
            sourceDeviceID: "device-a",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_120),
            listenedSeconds: 120,
            updatedAt: Date(timeIntervalSince1970: 1_120)
        )
        let duplicate = ListeningHistorySync(
            id: "shared-session",
            feedURL: "feed-a",
            episodeID: "episode-a",
            sourceDeviceID: "device-b",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_120),
            listenedSeconds: 120,
            updatedAt: Date(timeIntervalSince1970: 1_120)
        )

        let statistics = ListeningHistoryAggregation.globalStatistics(
            from: [first, duplicate]
        )

        XCTAssertEqual(statistics.sessionCount, 1)
        XCTAssertEqual(statistics.totalSeconds, 120)
    }

    func testListeningHistoryDeduplicatesLegacyClonesWithDifferentIDs() {
        let first = ListeningHistorySync(
            id: "phone-copy",
            feedURL: "feed-a",
            episodeID: "episode-a",
            sourceDeviceID: "device-a",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_120),
            startPosition: 10,
            endPosition: 130,
            listenedSeconds: 120,
            updatedAt: Date(timeIntervalSince1970: 1_120)
        )
        let clonedLegacyRecord = ListeningHistorySync(
            id: "mac-copy",
            feedURL: "feed-a",
            episodeID: "episode-a",
            sourceDeviceID: "device-b",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_120),
            startPosition: 10,
            endPosition: 130,
            listenedSeconds: 120,
            updatedAt: Date(timeIntervalSince1970: 1_120)
        )

        let statistics = ListeningHistoryAggregation.globalStatistics(
            from: [first, clonedLegacyRecord]
        )

        XCTAssertEqual(statistics.sessionCount, 1)
        XCTAssertEqual(statistics.totalSeconds, 120)
    }

    func testListeningHistoryDeduplicatesEquivalentFeedURLs() {
        let first = ListeningHistorySync(
            id: "secure-feed",
            feedURL: "https://example.com/feed.xml",
            episodeID: "episode-a",
            sourceDeviceID: "device-a",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_120),
            startPosition: 10,
            endPosition: 130,
            listenedSeconds: 120
        )
        let legacyClone = ListeningHistorySync(
            id: "legacy-feed",
            feedURL: "http://www.example.com/feed.xml/",
            episodeID: "episode-a",
            sourceDeviceID: "device-b",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_120),
            startPosition: 10,
            endPosition: 130,
            listenedSeconds: 120
        )

        let statistics = ListeningHistoryAggregation.globalStatistics(
            from: [first, legacyClone]
        )

        XCTAssertEqual(statistics.sessionCount, 1)
        XCTAssertEqual(statistics.totalSeconds, 120)
    }

    func testListeningHistoryDeduplicatesEquivalentSessionsWithPositionDrift() {
        let first = ListeningHistorySync(
            id: "phone-copy",
            feedURL: "https://example.com/feed.xml",
            episodeID: "episode-a",
            sourceDeviceID: "device-a",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_120),
            startPosition: 10,
            endPosition: 130,
            listenedSeconds: 120
        )
        let slightlyShifted = ListeningHistorySync(
            id: "mac-copy",
            feedURL: "https://example.com/feed.xml",
            episodeID: "episode-a",
            sourceDeviceID: "device-b",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_120),
            startPosition: 11.2,
            endPosition: 131.8,
            listenedSeconds: 120
        )

        let statistics = ListeningHistoryAggregation.globalStatistics(
            from: [first, slightlyShifted]
        )

        XCTAssertEqual(statistics.sessionCount, 1)
        XCTAssertEqual(statistics.totalSeconds, 120)
    }

    func testListeningHistoryCanFilterByDevice() {
        let records = [
            ListeningHistorySync(
                id: "session-a",
                feedURL: "feed-a",
                episodeID: "episode-a",
                sourceDeviceID: "device-a",
                sourceDeviceName: "iPhone",
                startedAt: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 1_060),
                listenedSeconds: 60
            ),
            ListeningHistorySync(
                id: "session-b",
                feedURL: "feed-a",
                episodeID: "episode-a",
                sourceDeviceID: "device-b",
                sourceDeviceName: "Mac",
                startedAt: Date(timeIntervalSince1970: 2_000),
                endedAt: Date(timeIntervalSince1970: 2_120),
                listenedSeconds: 120
            )
        ]

        let macHistory = ListeningHistoryAggregation.deduplicated(
            records,
            sourceDeviceID: "device-b"
        )

        XCTAssertEqual(macHistory.map(\.id), ["session-b"])
        XCTAssertEqual(macHistory.first?.sourceDeviceName, "Mac")
    }
}
