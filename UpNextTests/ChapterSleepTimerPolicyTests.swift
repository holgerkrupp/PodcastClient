import XCTest
@testable import UpNext

final class ChapterSleepTimerPolicyTests: XCTestCase {
    func testSleepTimerRemainingUsesProvidedClock() {
        let now = Date(timeIntervalSince1970: 10_000)
        let end = now.addingTimeInterval(90)

        XCTAssertEqual(SleepTimerPolicy.remaining(until: end, now: now), 90)
        XCTAssertEqual(
            SleepTimerPolicy.remaining(until: end, now: now.addingTimeInterval(30)),
            60
        )
        XCTAssertNil(SleepTimerPolicy.remaining(until: end, now: now.addingTimeInterval(90)))
    }

    func testChapterTimerIntervalAccountsForPlaybackRate() {
        XCTAssertEqual(
            SleepTimerPolicy.chapterTimerInterval(target: 300, position: 100, playbackRate: 2),
            100
        )
        XCTAssertEqual(
            SleepTimerPolicy.chapterTimerInterval(target: 100, position: 100, playbackRate: 1),
            1
        )
        XCTAssertEqual(
            SleepTimerPolicy.chapterTimerInterval(target: 300, position: 100, playbackRate: 0),
            800
        )
    }

    func testRestartChapterReferenceSurvivesRegeneratedChapterIdentityWhenMetadataMatches() {
        let episodeURL = URL(string: "https://example.com/episode.mp3")!
        let reference = SleepTimerChapterReference(
            episodeURL: episodeURL,
            chapterID: UUID(),
            title: "The middle",
            start: 120
        )
        let regenerated = ChapterSleepTimerOption(
            id: "120|The middle|1",
            chapterID: nil,
            episodeURL: episodeURL,
            title: "The middle",
            start: 120,
            stopBoundary: 240,
            isCurrent: true
        )

        XCTAssertTrue(SleepTimerPolicy.matches(reference, option: regenerated))
    }

    func testRestartChapterReferenceNeverMatchesAnotherEpisode() {
        let reference = SleepTimerChapterReference(
            episodeURL: URL(string: "https://example.com/one.mp3")!,
            chapterID: nil,
            title: "Chapter",
            start: 10
        )
        let option = ChapterSleepTimerOption(
            id: "10|Chapter|0",
            chapterID: nil,
            episodeURL: URL(string: "https://example.com/two.mp3")!,
            title: "Chapter",
            start: 10,
            stopBoundary: 30,
            isCurrent: true
        )

        XCTAssertFalse(SleepTimerPolicy.matches(reference, option: option))
    }

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
