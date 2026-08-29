import XCTest
@testable import UpNext

/// Session-level deduplication. Since the synced store stopped carrying
/// aggregates, these rows are the only thing any listening total is computed
/// from, so collapsing the duplicates CloudKit can deliver is what makes the
/// totals correct rather than merely close.
final class ListeningHistorySyncTests: XCTestCase {
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
