import XCTest
@testable import UpNext

@MainActor
final class PlayerProgressSliderViewTests: XCTestCase {
    func testChapterMarkerPositionsUseProvidedDuration() {
        let intro = Marker(start: 15, title: "Intro")
        let middle = Marker(start: 60, title: "Middle")
        let outro = Marker(start: 150, title: "Outro")

        let positions = PlayerProgressSliderView.chapterMarkerPositions(
            width: 200,
            duration: 200,
            markers: [intro, middle, outro]
        )

        XCTAssertEqual(positions.count, 3)
        XCTAssertEqual(positions[0], 15, accuracy: 0.001)
        XCTAssertEqual(positions[1], 60, accuracy: 0.001)
        XCTAssertEqual(positions[2], 150, accuracy: 0.001)
    }

    func testChapterMarkerPositionsIgnoreMarkersOutsideTimeline() {
        let zero = Marker(start: 0, title: "Zero")
        let valid = Marker(start: 25, title: "Valid")
        let overflow = Marker(start: 120, title: "Overflow")

        let positions = PlayerProgressSliderView.chapterMarkerPositions(
            width: 100,
            duration: 100,
            markers: [zero, valid, overflow]
        )

        XCTAssertEqual(positions.count, 1)
        XCTAssertEqual(positions[0], 25, accuracy: 0.001)
    }

    func testChapterScrubSnapsToNearestPlayableChapterStartWithinTolerance() {
        let skipped = Marker(start: 50, title: "Skipped")
        skipped.shouldPlay = false
        let bookmarks = Marker(start: 62, title: "Bookmark", type: .bookmark)
        let chapter = Marker(start: 70, title: "Chapter")

        let target = PlayerProgressSliderView.chapterSnapTarget(
            proposedValue: 66,
            duration: 200,
            range: 0...200,
            markers: [skipped, bookmarks, chapter],
            tolerance: 8
        )

        XCTAssertEqual(target, 70)
    }

    func testChapterScrubDoesNotSnapOutsideToleranceOrToOutOfRangeMarkers() {
        let outside = Marker(start: 250, title: "Outside")
        let chapter = Marker(start: 60, title: "Chapter")

        XCTAssertNil(PlayerProgressSliderView.chapterSnapTarget(
            proposedValue: 40,
            duration: 200,
            range: 0...200,
            markers: [outside, chapter],
            tolerance: 8
        ))
    }

    func testChapterSleepTimerCapturesCurrentBoundaryWithPredictableFallbacks() {
        XCTAssertEqual(
            ChapterSleepTimerPolicy.boundary(
                chapterEnd: 120,
                nextChapterStart: 110,
                episodeDuration: 300,
                position: 100,
                hasChapter: true
            ),
            120
        )
        XCTAssertEqual(
            ChapterSleepTimerPolicy.boundary(
                chapterEnd: nil,
                nextChapterStart: nil,
                episodeDuration: 300,
                position: 200,
                hasChapter: true
            ),
            300,
            "A final chapter without an explicit end falls back to the episode boundary."
        )
        XCTAssertNil(ChapterSleepTimerPolicy.boundary(
            chapterEnd: nil,
            nextChapterStart: nil,
            episodeDuration: 300,
            position: 200,
            hasChapter: false
        ))
        XCTAssertEqual(ChapterSleepTimerPolicy.boundary(
            chapterEnd: 150,
            nextChapterStart: 180,
            episodeDuration: 300,
            position: 151,
            hasChapter: true
        ), 180, "If the captured end is already behind the playhead, use the next chapter boundary.")
    }

    func testChapterSleepTimerRemainingNeverGoesNegative() {
        XCTAssertEqual(ChapterSleepTimerPolicy.remaining(target: 120, position: 30), 90)
        XCTAssertEqual(ChapterSleepTimerPolicy.remaining(target: 120, position: 121), 0)
    }
}
