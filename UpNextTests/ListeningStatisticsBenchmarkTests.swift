import Foundation
import XCTest
@testable import UpNext

final class ListeningStatisticsBenchmarkTests: XCTestCase {
    func testAggregatesTenThousandSyntheticSessions() {
        var sessions: [ListeningStatisticsSessionValue] = []
        sessions.reserveCapacity(10_000)
        let base = Date(timeIntervalSince1970: 1_600_000_000)

        for index in 0..<10_000 {
            let start = base.addingTimeInterval(Double(index) * 3_600)
            sessions.append(
                ListeningStatisticsSessionValue(
                    id: "benchmark-\(index)",
                    feedURL: "https://example.com/feed-\(index % 20)",
                    episodeID: "episode-\(index)",
                    podcastName: "Podcast \(index % 20)",
                    sourceDeviceID: index.isMultiple(of: 2) ? "phone" : "mac",
                    startedAt: start,
                    endedAt: start.addingTimeInterval(1_800),
                    listenedSeconds: 1_800,
                    silenceGapTimeSavedSeconds: 30,
                    playbackRateTimeSavedSeconds: 120
                )
            )
        }

        let query = ListeningStatisticsQuery(
            period: .forever,
            start: .distantPast,
            end: .distantFuture
        )
        let start = ProcessInfo.processInfo.systemUptime
        let snapshot = ListeningStatisticsAggregator.snapshot(
            sessions: sessions,
            baselines: [],
            completions: [],
            completionDataAvailable: false,
            query: query
        )
        let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000

        XCTAssertEqual(snapshot.sessionCount, 10_000)
        XCTAssertEqual(snapshot.totalSeconds, 18_000_000, accuracy: 0.001)
        XCTAssertEqual(snapshot.podcasts.count, 20)
        print("Listening statistics benchmark: sessions=10000 aggregate_ms=\(String(format: \"%.2f\", milliseconds))")
    }
}
