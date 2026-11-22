import XCTest
@testable import UpNext

final class ChapterSleepTimerPolicyTests: XCTestCase {
    func testExplicitChapterEndWins() {
        XCTAssertEqual(
            ChapterSleepTimerPolicy.effectiveEnd(
                chapterEnd: 120,
                nextChapterStart: 100,
                episodeDuration: 500,
                chapterStart: 60
            ),
            120
        )
    }

    func testNextChapterStartFillsMissingEnd() {
        XCTAssertEqual(
            ChapterSleepTimerPolicy.effectiveEnd(
                chapterEnd: nil,
                nextChapterStart: 240,
                episodeDuration: 500,
                chapterStart: 120
            ),
            240
        )
    }

    func testEpisodeDurationEndsLastChapter() {
        XCTAssertEqual(
            ChapterSleepTimerPolicy.effectiveEnd(
                chapterEnd: nil,
                nextChapterStart: nil,
                episodeDuration: 500,
                chapterStart: 420
            ),
            500
        )
    }

    func testInvalidOrNonAdvancingBoundariesAreIgnored() {
        XCTAssertNil(
            ChapterSleepTimerPolicy.effectiveEnd(
                chapterEnd: 100,
                nextChapterStart: 110,
                episodeDuration: 90,
                chapterStart: 100
            )
        )
    }
}
