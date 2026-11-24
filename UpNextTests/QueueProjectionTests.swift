import XCTest
@testable import UpNext

final class QueueProjectionTests: XCTestCase {
    private let firstURL = URL(string: "https://example.com/one.mp3")!
    private let secondURL = URL(string: "https://example.com/two.mp3")!
    private let thirdURL = URL(string: "https://example.com/three.mp3")!

    func testFilteringKeepsAuthoritativeOrderAndDoesNotChangeMembership() {
        let projection = QueueProjection(
            playlistID: UUID(),
            playlistTitle: "Up Next",
            isSmartPlaylist: false,
            entries: [
                value("one", url: firstURL, duration: 10 * 60, inProgress: true),
                value("two", url: secondURL, duration: 40 * 60, downloaded: true),
                value("three", url: thirdURL, duration: nil, downloaded: true)
            ]
        )

        var filters = QueueFilterState()
        filters.downloadedOnly = true
        filters.maximumDurationMinutes = 45

        let filtered = projection.filtered(using: filters)

        XCTAssertEqual(filtered.entries.map(\.episodeURL), [secondURL])
        XCTAssertEqual(projection.entries.map(\.episodeURL), [firstURL, secondURL, thirdURL])
        XCTAssertEqual(projection.count, 3)
    }

    func testInProgressAndDurationFiltersUseExistingCompletionSemantics() {
        let projection = QueueProjection(
            entries: [
                value("started", url: firstURL, duration: 20 * 60, inProgress: true),
                value("finished", url: secondURL, duration: 10 * 60, inProgress: true, isPlayed: true),
                value("unstarted", url: thirdURL, duration: 5 * 60)
            ]
        )

        var filters = QueueFilterState()
        filters.inProgress = true
        filters.maximumDurationMinutes = 30

        XCTAssertEqual(
            projection.filtered(using: filters).entries.map(\.title),
            ["started"]
        )
    }

    func testUnknownDurationIsExcludedByDurationFilterAndReportedInTotals() {
        let projection = QueueProjection(
            entries: [
                value("known", url: firstURL, duration: 20 * 60),
                value("unknown", url: secondURL, duration: nil)
            ]
        )

        var filters = QueueFilterState()
        filters.maximumDurationMinutes = 30

        XCTAssertEqual(projection.filtered(using: filters).entries.map(\.title), ["known"])
        XCTAssertEqual(projection.knownRemainingDuration, 20 * 60)
        XCTAssertTrue(projection.hasUnknownDuration)
    }

    func testRemainingDurationClampsResumePosition() {
        let projection = QueueProjection(
            entries: [
                value("one", url: firstURL, duration: 60 * 60, playPosition: 15 * 60),
                value("two", url: secondURL, duration: 30 * 60, playPosition: 40 * 60)
            ]
        )

        XCTAssertEqual(projection.knownRemainingDuration, 45 * 60)
    }

    func testUpcomingUsesActualSequenceAndMarksIndependentPlayback() {
        let projection = QueueProjection(
            playlistID: UUID(),
            playlistTitle: "Selected",
            isSmartPlaylist: true,
            entries: [
                value("one", url: firstURL),
                value("two", url: secondURL),
                value("three", url: thirdURL)
            ]
        )

        let upcoming = projection.upcoming(after: secondURL)
        XCTAssertFalse(upcoming.isIndependentPlayback)
        XCTAssertTrue(upcoming.isSmartPlaylist)
        XCTAssertEqual(upcoming.upcoming.map(\.episodeURL), [thirdURL])

        let independent = projection.upcoming(after: URL(string: "https://example.com/outside.mp3")!)
        XCTAssertTrue(independent.isIndependentPlayback)
        XCTAssertTrue(independent.upcoming.isEmpty)
    }

    func testDuplicateOccurrencesHaveStableDistinctPresentationIDs() {
        let projection = QueueProjection(
            entries: [
                value("same", url: firstURL),
                value("same", url: firstURL)
            ]
        )

        XCTAssertEqual(projection.entries.map(\.id), ["same", "same#1"])
        XCTAssertEqual(projection.entries.map(\.episodeURL), [firstURL, firstURL])
    }

    private func value(
        _ title: String,
        url: URL,
        duration: TimeInterval? = 30 * 60,
        playPosition: TimeInterval = 0,
        inProgress: Bool = false,
        isPlayed: Bool = false,
        downloaded: Bool = false
    ) -> QueueEpisodeValue {
        QueueEpisodeValue(
            stableIdentityKey: title,
            episodeURL: url,
            title: title,
            podcastTitle: "Example",
            duration: duration,
            playPosition: playPosition,
            maxPlayPosition: playPosition,
            hasPlaybackHistory: inProgress || isPlayed,
            isPlayed: isPlayed,
            isDownloaded: downloaded
        )
    }
}
