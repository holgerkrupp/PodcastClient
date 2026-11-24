import Foundation
import XCTest
@testable import UpNext

final class InboxTriageModelsTests: XCTestCase {
    func testGroupingKeepsEpisodesInReleaseOrderAndReportsCounts() {
        let episodes = [
            projection(id: "a", title: "A", podcastKey: "show-1", podcastTitle: "Show One", date: date("2026-11-24")),
            projection(id: "b", title: "B", podcastKey: "show-2", podcastTitle: "Show Two", date: date("2026-11-23")),
            projection(id: "c", title: "C", podcastKey: "show-1", podcastTitle: "Show One", date: date("2026-11-22"))
        ]

        let groups = InboxEpisodeProjection.groups(from: episodes, grouping: .podcast)

        XCTAssertEqual(groups.map(\.title), ["Show One", "Show Two"])
        XCTAssertEqual(groups.first?.episodes.map(\.id), ["a", "c"])
        XCTAssertEqual(groups.first?.episodes.count, 2)
    }

    func testDayGroupingUsesCalendarBoundaries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let episodes = [
            projection(id: "late", title: "Late", podcastKey: "show", podcastTitle: "Show", date: date("2026-11-24T23:30:00Z")),
            projection(id: "early", title: "Early", podcastKey: "show", podcastTitle: "Show", date: date("2026-11-25T00:30:00Z"))
        ]

        let groups = InboxEpisodeProjection.groups(from: episodes, grouping: .day, calendar: calendar)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.flatMap { $0.episodes.map(\.id) }, ["early", "late"])
    }

    func testCleanupNeverIsOffAndProtectedItemsStayOut() {
        let now = date("2026-11-24")
        let episodes = [
            projection(id: "old", title: "Old", podcastKey: "show", podcastTitle: "Show", date: date("2026-10-01")),
            projection(id: "saved", title: "Saved", podcastKey: "show", podcastTitle: "Show", date: date("2026-09-01"), saved: true),
            projection(id: "favorite", title: "Favorite", podcastKey: "show", podcastTitle: "Show", date: date("2026-08-01"), favorite: true),
            projection(id: "queued", title: "Queued", podcastKey: "show", podcastTitle: "Show", date: date("2026-07-01"), queued: true),
            projection(id: "started", title: "Started", podcastKey: "show", podcastTitle: "Show", date: date("2026-06-01"), history: true)
        ]

        XCTAssertTrue(InboxCleanupPolicy.never.eligibleIDs(from: episodes, now: now).isEmpty)
        XCTAssertEqual(
            InboxCleanupPolicy.olderThanDays(30).eligibleIDs(from: episodes, now: now),
            ["old"]
        )
    }

    func testKeepLatestPerPodcastRetainsNewestUnprotectedEpisodes() {
        let episodes = [
            projection(id: "new", title: "New", podcastKey: "show", podcastTitle: "Show", date: date("2026-11-20")),
            projection(id: "middle", title: "Middle", podcastKey: "show", podcastTitle: "Show", date: date("2026-11-10")),
            projection(id: "old", title: "Old", podcastKey: "show", podcastTitle: "Show", date: date("2026-11-01")),
            projection(id: "other", title: "Other", podcastKey: "other", podcastTitle: "Other", date: date("2026-11-01"))
        ]

        XCTAssertEqual(
            InboxCleanupPolicy.keepLatestPerPodcast(1).eligibleIDs(from: episodes),
            ["middle", "old"]
        )
    }

    private func projection(
        id: String,
        title: String,
        podcastKey: String,
        podcastTitle: String,
        date: Date,
        saved: Bool = false,
        favorite: Bool = false,
        queued: Bool = false,
        history: Bool = false
    ) -> InboxEpisodeProjection {
        InboxEpisodeProjection(
            id: id,
            title: title,
            podcastKey: podcastKey,
            podcastTitle: podcastTitle,
            publishedAt: date,
            remainingDuration: 1_800,
            isSavedForLater: saved,
            isFavorite: favorite,
            isQueued: queued,
            isDownloaded: false,
            hasPlaybackHistory: history
        )
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.date(from: value.contains("T") ? value : value + "T00:00:00Z")!
    }
}
