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
}
