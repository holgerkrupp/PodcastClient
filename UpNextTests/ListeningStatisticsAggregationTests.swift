import Foundation
import XCTest
@testable import UpNext

final class ListeningStatisticsAggregationTests: XCTestCase {
    func testCrossMonthSessionUsesStartInclusiveEndExclusiveBuckets() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 23, minute: 30)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 1, hour: 0, minute: 30)))
        let queryStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let queryEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)))

        let snapshot = ListeningStatisticsAggregator.snapshot(
            sessions: [session(start: start, end: end, listenedSeconds: 3_600)],
            baselines: [],
            completions: [],
            completionDataAvailable: true,
            query: ListeningStatisticsQuery(
                period: .month,
                start: queryStart,
                end: queryEnd,
                calendar: calendar
            )
        )

        XCTAssertEqual(snapshot.totalSeconds, 3_600, accuracy: 0.001)
        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertEqual(snapshot.buckets.map(\.totalSeconds), [1_800, 1_800])
    }

    func testDSTUsesActualTimestampDurationAndDoesNotInventMissingHour() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 1, minute: 30)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 4, minute: 30)))
        let dayStart = calendar.startOfDay(for: start)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        let snapshot = ListeningStatisticsAggregator.snapshot(
            sessions: [session(start: start, end: end, listenedSeconds: end.timeIntervalSince(start))],
            baselines: [],
            completions: [],
            completionDataAvailable: true,
            query: ListeningStatisticsQuery(
                period: .day,
                start: dayStart,
                end: dayEnd,
                calendar: calendar
            )
        )

        XCTAssertEqual(end.timeIntervalSince(start), 7_200, accuracy: 0.001)
        XCTAssertEqual(snapshot.totalSeconds, 7_200, accuracy: 0.001)
    }

    func testCrossDeviceDuplicateUsesNewestCanonicalSession() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(600)
        let older = session(
            id: "phone-copy",
            deviceID: "phone",
            start: start,
            end: end,
            listenedSeconds: 600,
            updatedAt: start
        )
        let newer = session(
            id: "mac-copy",
            deviceID: "mac",
            start: start,
            end: end,
            listenedSeconds: 600,
            updatedAt: end
        )

        let deduplicated = ListeningStatisticsAggregator.deduplicatedSessions([older, newer])

        XCTAssertEqual(deduplicated.count, 1)
        XCTAssertEqual(deduplicated.first?.sourceDeviceID, "mac")
    }

    func testSavedTimeAndCompletedEpisodesUseOnlyRecordedValues() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(100)
        let snapshot = ListeningStatisticsAggregator.snapshot(
            sessions: [session(start: start, end: end, listenedSeconds: 100, silenceSaved: 12, playbackSaved: 25)],
            baselines: [],
            completions: [
                ListeningStatisticsCompletionValue(episodeIdentity: "episode-1", completedAt: end),
                ListeningStatisticsCompletionValue(episodeIdentity: "episode-1", completedAt: end),
                ListeningStatisticsCompletionValue(episodeIdentity: "episode-2", completedAt: end)
            ],
            completionDataAvailable: true,
            query: ListeningStatisticsQuery(
                period: .forever,
                start: .distantPast,
                end: .distantFuture
            )
        )

        XCTAssertEqual(snapshot.totalSeconds, 100, accuracy: 0.001)
        XCTAssertEqual(snapshot.silenceGapTimeSavedSeconds, 12, accuracy: 0.001)
        XCTAssertEqual(snapshot.playbackRateTimeSavedSeconds, 25, accuracy: 0.001)
        XCTAssertEqual(snapshot.completedEpisodeCount, 2)
    }

    func testMalformedAndEmptyHistoryProducesAnHonestEmptySnapshot() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let malformed = session(start: now, end: now, listenedSeconds: 300)
        let empty = ListeningStatisticsAggregator.snapshot(
            sessions: [malformed],
            baselines: [],
            completions: [],
            completionDataAvailable: true,
            query: ListeningStatisticsQuery(period: .forever, start: .distantPast, end: .distantFuture)
        )

        XCTAssertEqual(empty.totalSeconds, 0)
        XCTAssertEqual(empty.sessionCount, 0)
        XCTAssertTrue(empty.podcasts.isEmpty)
        XCTAssertEqual(empty.completedEpisodeCount, 0)
    }

    func testAllTimeBaselineIsNotDoubleCountedWithMigratedRows() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let migrated = session(
            id: "migrated",
            start: start,
            end: start.addingTimeInterval(600),
            listenedSeconds: 600,
            isLegacyMigrated: true
        )
        let live = session(
            id: "live",
            start: start.addingTimeInterval(1_000),
            end: start.addingTimeInterval(1_600),
            listenedSeconds: 600
        )
        let snapshot = ListeningStatisticsAggregator.snapshot(
            sessions: [migrated, live],
            baselines: [ListeningStatisticsBaselineValue(feedURL: "https://example.com/feed", totalSeconds: 600)],
            completions: [],
            completionDataAvailable: true,
            query: ListeningStatisticsQuery(period: .forever, start: .distantPast, end: .distantFuture)
        )

        XCTAssertEqual(snapshot.totalSeconds, 1_200, accuracy: 0.001)
    }

    private func session(
        id: String = UUID().uuidString,
        deviceID: String = "phone",
        episodeID: String = "episode-1",
        start: Date,
        end: Date,
        listenedSeconds: Double,
        silenceSaved: Double = 0,
        playbackSaved: Double = 0,
        isLegacyMigrated: Bool = false,
        updatedAt: Date = .distantPast
    ) -> ListeningStatisticsSessionValue {
        ListeningStatisticsSessionValue(
            id: id,
            feedURL: "https://example.com/feed",
            episodeID: episodeID,
            podcastName: "Example Podcast",
            episodeTitle: "Episode",
            sourceDeviceID: deviceID,
            startedAt: start,
            endedAt: end,
            listenedSeconds: listenedSeconds,
            silenceGapTimeSavedSeconds: silenceSaved,
            playbackRateTimeSavedSeconds: playbackSaved,
            isLegacyMigrated: isLegacyMigrated,
            updatedAt: updatedAt
        )
    }
}
