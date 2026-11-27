import XCTest
@testable import UpNext

/// Playback highlighting from verified audio-clock publisher word timing (#492).
@MainActor
final class TranscriptEnhancedWordTrackingTests: XCTestCase {
    private typealias Tracker = TranscriptPlaybackTracker

    private func segment(
        _ text: String, start: TimeInterval, end: TimeInterval, native: [(String, TimeInterval, TimeInterval)] = []
    ) -> TranscriptSegment {
        TranscriptSegment(id: UUID(), speaker: nil, text: text, startTime: start, endTime: end,
                          lineIDs: [], timedSpans: spans(in: text, native))
    }

    private func spans(in text: String, _ timing: [(String, TimeInterval, TimeInterval)]) -> [TranscriptTimedSpan] {
        let nsText = text as NSString
        return timing.map { word, start, end in
            let range = nsText.range(of: word)
            return TranscriptTimedSpan(location: range.location, length: range.length, startTime: start, endTime: end)
        }
    }

    private func word(_ active: Tracker.Active?, in segments: [TranscriptSegment]) -> String? {
        guard let active, let location = active.location, let length = active.length,
              let segment = segments.first(where: { $0.id == active.segmentID }) else { return nil }
        return (segment.text as NSString).substring(with: NSRange(location: location, length: length))
    }

    func testEnhancedWordUsesRawAudioTimeWithoutSecondConversion() {
        // The transcript clock (3 s) lies inside the segment, but the audio
        // clock (7.2 s) is where "gamma" is actually spoken. Converting the
        // enhanced spans again would have highlighted "alpha".
        let value = segment("alpha beta gamma", start: 0, end: 10)
        let index = Tracker.EnhancedWordIndex(
            [value.id: spans(in: value.text, [("alpha", 3, 3.4), ("beta", 5, 5.4), ("gamma", 7, 7.5)])],
            segments: [value]
        )
        let active = Tracker.lookup(segments: [value], at: 3.2, audioTime: 7.2, enhancedWords: index)
        XCTAssertEqual(word(active, in: [value]), "gamma")
        XCTAssertEqual(active?.quality, .enhancedWords)
    }

    func testNativeWordSpansWinOverEnhancedWords() {
        let value = segment("alpha beta gamma", start: 0, end: 10, native: [("alpha", 1, 1.5)])
        let index = Tracker.EnhancedWordIndex([value.id: spans(in: value.text, [("gamma", 7, 7.5)])], segments: [value])
        let active = Tracker.lookup(segments: [value], at: 1.2, audioTime: 7.2, enhancedWords: index)
        XCTAssertEqual(word(active, in: [value]), "alpha")
        XCTAssertEqual(active?.quality, .nativeWords)
    }

    func testFallsBackToCueWithoutEnhancedWord() {
        let value = segment("alpha beta gamma", start: 0, end: 10)
        let index = Tracker.EnhancedWordIndex([value.id: spans(in: value.text, [("gamma", 7, 7.5)])], segments: [value])
        let active = Tracker.lookup(segments: [value], at: 2, audioTime: 2, enhancedWords: index, isBridgeAllowed: { _, _ in true })
        XCTAssertEqual(active?.segmentID, value.id)
        XCTAssertNil(active?.location)
        XCTAssertNil(active?.quality)
    }

    func testUnverifiedAudioPreventsEnhancedCrossSegmentJump() {
        let first = segment("alpha beta", start: 0, end: 10)
        let second = segment("gamma delta", start: 10, end: 20)
        let segments = [first, second]
        let index = Tracker.EnhancedWordIndex([second.id: spans(in: second.text, [("gamma", 4, 4.5)])], segments: segments)

        let unverified = Tracker.lookup(segments: segments, at: 2, audioTime: 4.2, enhancedWords: index,
                                        isAudioVerified: { _ in false })
        XCTAssertEqual(unverified?.segmentID, first.id)
        XCTAssertNil(unverified?.location)

        let verified = Tracker.lookup(segments: segments, at: 2, audioTime: 4.2, enhancedWords: index)
        XCTAssertEqual(verified?.segmentID, second.id)
        XCTAssertEqual(word(verified, in: segments), "gamma")
    }

    func testContinuityBridgesOneUnmatchedWordBetweenEnhancedWords() {
        let value = segment("alpha beta gamma", start: 0, end: 10)
        let index = Tracker.EnhancedWordIndex(
            [value.id: spans(in: value.text, [("alpha", 6, 6.4), ("gamma", 7, 7.4)])], segments: [value]
        )
        let bridged = Tracker.lookup(segments: [value], at: 1, audioTime: 6.6, enhancedWords: index, isBridgeAllowed: { _, _ in true })
        XCTAssertEqual(word(bridged, in: [value]), "alpha")
        XCTAssertEqual(bridged?.quality, .enhancedWords)

        // Never across unverified (for example advertising) audio.
        let blocked = Tracker.lookup(segments: [value], at: 1, audioTime: 6.6, enhancedWords: index,
                                     isAudioVerified: { _ in false }) { _, _ in true }
        XCTAssertNil(blocked?.location)
    }

    func testEmptyUpdateClearsEnhancedWords() {
        let value = segment("alpha beta gamma", start: 0, end: 10)
        let words = [value.id: spans(in: value.text, [("gamma", 7, 7.5)])]
        XCTAssertFalse(Tracker.EnhancedWordIndex(words, segments: [value]).isEmpty)

        let cleared = Tracker.EnhancedWordIndex([:], segments: [value])
        XCTAssertTrue(cleared.isEmpty)
        let active = Tracker.lookup(segments: [value], at: 7.2, audioTime: 7.2, enhancedWords: cleared)
        XCTAssertEqual(active?.segmentID, value.id)
        XCTAssertNil(active?.location)

        // The tracker API accepts both replacing and clearing without starting.
        let tracker = Tracker()
        tracker.updateEnhancedWords(words)
        tracker.updateEnhancedWords([:])
        XCTAssertNil(tracker.active)
    }
}
