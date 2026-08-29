import XCTest
@testable import UpNext

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
}
