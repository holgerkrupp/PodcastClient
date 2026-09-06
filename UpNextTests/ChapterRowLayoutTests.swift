import SwiftData
import XCTest
@testable import UpNext

/// Pins the per-row values the chapter list draws.
///
/// They used to be derived inside the `ForEach` body, where every one of them
/// re-ran the filter-and-sort over the episode's whole chapter list. Moving the
/// derivation into one pass is what makes drawing linear; these cover that the
/// move did not change what gets drawn.
final class ChapterRowLayoutTests: XCTestCase {
    private func markers(_ starts: [Double], duration: TimeInterval? = nil) -> [Marker] {
        starts.enumerated().map { index, start in
            Marker(
                start: start,
                title: "Chapter \(index)",
                type: .mp3,
                duration: duration
            )
        }
    }

    func testCurrentChapterIsTheLastOneStartedAndFillsProportionally() {
        let chapters = markers([0, 100, 300])

        let rows = ChapterRowLayout.rows(
            markers: chapters,
            playPosition: 150,
            hasPlaybackHistory: true,
            episodeDuration: 400
        )

        XCTAssertEqual(rows.map(\.isCurrent), [false, true, false])
        // 150 sits a quarter of the way through the 100...300 chapter.
        XCTAssertEqual(rows[1].backgroundProgress, 0.25, accuracy: 0.0001)
        XCTAssertEqual(rows.map(\.isLast), [false, false, true])
    }

    /// The last chapter has no successor to borrow an end time from, so it falls
    /// back to the episode duration.
    func testLastChapterUsesEpisodeDurationAsItsEnd() {
        let chapters = markers([0, 100, 300])

        let rows = ChapterRowLayout.rows(
            markers: chapters,
            playPosition: 350,
            hasPlaybackHistory: true,
            episodeDuration: 400
        )

        XCTAssertTrue(rows[2].isCurrent)
        // 350 of the 300...400 chapter.
        XCTAssertEqual(rows[2].backgroundProgress, 0.5, accuracy: 0.0001)
    }

    /// A chapter carrying its own duration ends where that says, not where the
    /// next chapter begins.
    func testOwnEndTimeWinsOverTheNextChapterStart() {
        let chapters = markers([0, 100, 300], duration: 20)

        let rows = ChapterRowLayout.rows(
            markers: chapters,
            playPosition: 110,
            hasPlaybackHistory: true,
            episodeDuration: 400
        )

        XCTAssertTrue(rows[1].isCurrent)
        // 110 of the 100...120 chapter, not of 100...300.
        XCTAssertEqual(rows[1].backgroundProgress, 0.5, accuracy: 0.0001)
    }

    func testNonCurrentRowsShowStoredProgressOnlyWithPlaybackHistory() {
        let chapters = markers([0, 100, 300])
        chapters[0].progress = 0.75
        chapters[2].progress = 0.5

        let withHistory = ChapterRowLayout.rows(
            markers: chapters,
            playPosition: 150,
            hasPlaybackHistory: true,
            episodeDuration: 400
        )
        XCTAssertEqual(withHistory[0].backgroundProgress, 0.75, accuracy: 0.0001)
        XCTAssertEqual(withHistory[2].backgroundProgress, 0.5, accuracy: 0.0001)

        let withoutHistory = ChapterRowLayout.rows(
            markers: chapters,
            playPosition: 150,
            hasPlaybackHistory: false,
            episodeDuration: 400
        )
        XCTAssertEqual(withoutHistory[0].backgroundProgress, 0)
        XCTAssertEqual(withoutHistory[2].backgroundProgress, 0)
    }

    func testStoredProgressIsClampedAndNonFiniteValuesAreIgnored() {
        let chapters = markers([0, 100])
        chapters[0].progress = 4.2

        var rows = ChapterRowLayout.rows(
            markers: chapters,
            playPosition: 150,
            hasPlaybackHistory: true,
            episodeDuration: 400
        )
        XCTAssertEqual(rows[0].backgroundProgress, 1.0)

        chapters[0].progress = .nan
        rows = ChapterRowLayout.rows(
            markers: chapters,
            playPosition: 150,
            hasPlaybackHistory: true,
            episodeDuration: 400
        )
        XCTAssertEqual(rows[0].backgroundProgress, 0.0)
    }

    /// No position to show — nothing is current and nothing fills.
    func testNoPlayPositionLeavesEveryRowEmptyAndNoneCurrent() {
        let chapters = markers([0, 100, 300])
        chapters[0].progress = 0.9

        let rows = ChapterRowLayout.rows(
            markers: chapters,
            playPosition: nil,
            hasPlaybackHistory: true,
            episodeDuration: 400
        )

        XCTAssertEqual(rows.filter(\.isCurrent).count, 0)
        // Without a current chapter every row falls to its stored progress.
        XCTAssertEqual(rows[0].backgroundProgress, 0.9, accuracy: 0.0001)
        XCTAssertEqual(rows[1].backgroundProgress, 0)
    }

    /// A position before the first chapter starts.
    func testPositionBeforeTheFirstChapterMarksNothingCurrent() {
        let chapters = markers([10, 100])

        let rows = ChapterRowLayout.rows(
            markers: chapters,
            playPosition: 5,
            hasPlaybackHistory: true,
            episodeDuration: 400
        )

        XCTAssertEqual(rows.filter(\.isCurrent).count, 0)
    }

    func testEmptyMarkerListProducesNoRows() {
        XCTAssertTrue(
            ChapterRowLayout.rows(
                markers: [],
                playPosition: 10,
                hasPlaybackHistory: true,
                episodeDuration: 400
            ).isEmpty
        )
    }

    /// Chapters sharing a start time keep their incoming order, so two passes
    /// over the same list cannot disagree about which one is current.
    @MainActor
    func testChaptersSortDeterministicallyWhenStartTimesTie() throws {
        let container = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let episode = Episode(
            guid: "tied-starts",
            title: "Tied",
            url: URL(string: "https://example.com/tied.mp3")!,
            podcast: nil
        )
        let tied = (0..<8).map { index in
            Marker(start: 100, title: "Tied \(index)", type: .mp3)
        }
        episode.chapters = tied
        container.mainContext.insert(episode)

        let first = episode.chaptersForDisplay(preferredType: .mp3).map(\.title)
        let second = episode.chaptersForDisplay(preferredType: .mp3).map(\.title)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, tied.count)
    }
}
