import XCTest
@testable import UpNext

/// Display-only highlight continuity across isolated unmatched publisher words (#489).
@MainActor
final class TranscriptHighlightContinuityTests: XCTestCase {

    /// Times every listed word (by text) and leaves the others untimed.
    private func segment(_ text: String, timing: [(String, TimeInterval, TimeInterval)]) -> TranscriptSegment {
        let nsText = text as NSString
        let spans = timing.map { word, start, end in
            let range = nsText.range(of: word)
            return TranscriptTimedSpan(location: range.location, length: range.length, startTime: start, endTime: end)
        }
        return make(text, spans)
    }

    private func make(_ text: String, _ spans: [TranscriptTimedSpan]) -> TranscriptSegment {
        TranscriptSegment(id: UUID(), speaker: nil, text: text, startTime: 0, endTime: 10,
                          lineIDs: [], timedSpans: spans)
    }

    private func highlighted(_ segment: TranscriptSegment, at time: TimeInterval, allow: Bool = true) -> String? {
        let active = TranscriptPlaybackTracker.lookup(segments: [segment], at: time) { _, _ in allow }
        guard let location = active?.location, let length = active?.length else { return nil }
        return (segment.text as NSString).substring(with: NSRange(location: location, length: length))
    }

    func testBridgesOneIsolatedUnmatchedWord() {
        let value = segment("alpha beta gamma", timing: [("alpha", 1, 1.4), ("gamma", 2, 2.4)])
        XCTAssertEqual(highlighted(value, at: 1.6), "alpha")
        XCTAssertEqual(highlighted(value, at: 2.1), "gamma")
    }

    func testBridgesTwoIsolatedUnmatchedWords() {
        let value = segment("alpha beta delta gamma", timing: [("alpha", 1, 1.4), ("gamma", 2.5, 2.9)])
        XCTAssertEqual(highlighted(value, at: 2.0), "alpha")
    }

    func testNoBridgeForMoreThanTwoWords() {
        let value = segment("alpha beta delta epsilon gamma", timing: [("alpha", 1, 1.4), ("gamma", 2, 2.4)])
        XCTAssertNil(highlighted(value, at: 1.6))
    }

    func testNoBridgeForLongTimeGap() {
        let value = segment("alpha beta gamma", timing: [("alpha", 1, 1.4), ("gamma", 3, 3.4)])
        XCTAssertGreaterThan(3 - 1.4, TranscriptHighlightContinuity.maximumGap)
        XCTAssertNil(highlighted(value, at: 2))
    }

    func testNoBridgeAcrossAdOrUnverifiedGap() {
        let value = segment("alpha beta gamma", timing: [("alpha", 1, 1.4), ("gamma", 2, 2.4)])
        XCTAssertNil(highlighted(value, at: 1.6, allow: false))
    }

    func testNoBridgeWithoutBridgePolicyOrForPausesWithoutWords() {
        let value = segment("alpha beta gamma", timing: [("alpha", 1, 1.4), ("gamma", 2, 2.4)])
        XCTAssertNil(TranscriptPlaybackTracker.lookup(segments: [value], at: 1.6)?.location)
        let adjacent = segment("alpha gamma", timing: [("alpha", 1, 1.4), ("gamma", 2, 2.4)])
        XCTAssertNil(highlighted(adjacent, at: 1.6))
    }

    func testNoBridgeFromCueLevelNeighbour() {
        let text = "alpha beta gamma"
        let value = make(text, [
            TranscriptTimedSpan(location: 0, length: 5, startTime: 1, endTime: 1.4, cueLevel: true),
            TranscriptTimedSpan(location: 11, length: 5, startTime: 2, endTime: 2.4)
        ])
        XCTAssertNil(highlighted(value, at: 1.6))
    }

    func testBridgeDoesNotMutateSpansOrTimeUnmatchedWord() {
        let value = segment("alpha beta gamma", timing: [("alpha", 1, 1.4), ("gamma", 2, 2.4)])
        let before = value.timedSpans
        var gapBounds: (TimeInterval, TimeInterval)?
        let bridged = TranscriptHighlightContinuity.bridgedSpan(in: value, at: 1.6) { start, end in
            gapBounds = (start, end)
            return true
        }
        XCTAssertEqual(bridged, before[0])
        XCTAssertEqual(gapBounds?.0, 1.4)
        XCTAssertEqual(gapBounds?.1, 2)
        XCTAssertEqual(value.timedSpans, before)
        XCTAssertNil(value.activeSpan(at: 1.6))
    }
}
