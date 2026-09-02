import XCTest
@testable import UpNext

final class ChapterSkipPlanTests: XCTestCase {
    func testConsecutiveSkippedChaptersBecomeOneImmediateSeek() throws {
        let firstID = UUID()
        let secondID = UUID()
        let plan = ChapterSkipPlan(entries: [
            .init(id: nil, start: 0, shouldPlay: true),
            .init(id: firstID, start: 10, shouldPlay: false),
            .init(id: secondID, start: 20, shouldPlay: false),
            .init(id: nil, start: 35, shouldPlay: true)
        ])

        XCTAssertEqual(plan.boundaryTimes, [10])
        let segment = try XCTUnwrap(plan.segment(at: 10))
        XCTAssertEqual(segment.resumeAt, 35)
        XCTAssertEqual(segment.chapterIDs, [firstID, secondID])
        XCTAssertNotNil(plan.segment(at: 34.99))
        XCTAssertNil(plan.segment(at: 35))
    }

    func testChangingSelectionsBuildsDifferentBoundariesAndTargets() throws {
        let selected = ChapterSkipPlan(entries: [
            .init(id: nil, start: 0, shouldPlay: true),
            .init(id: nil, start: 10, shouldPlay: false),
            .init(id: nil, start: 20, shouldPlay: true)
        ])
        let deselected = ChapterSkipPlan(entries: [
            .init(id: nil, start: 0, shouldPlay: true),
            .init(id: nil, start: 10, shouldPlay: false),
            .init(id: nil, start: 20, shouldPlay: false)
        ])

        XCTAssertEqual(try XCTUnwrap(selected.segment(at: 10)).resumeAt, 20)
        XCTAssertNil(try XCTUnwrap(deselected.segment(at: 10)).resumeAt)
    }

    func testInvalidChapterStartsAreIgnoredAndEntriesAreSorted() {
        let plan = ChapterSkipPlan(entries: [
            .init(id: nil, start: 30, shouldPlay: false),
            .init(id: nil, start: .nan, shouldPlay: false),
            .init(id: nil, start: 10, shouldPlay: false),
            .init(id: nil, start: 20, shouldPlay: true)
        ])

        XCTAssertEqual(plan.boundaryTimes, [10, 30])
        XCTAssertEqual(plan.segment(at: 10)?.resumeAt, 20)
        XCTAssertNil(plan.segment(at: 30)?.resumeAt)
    }
}
