import XCTest
@testable import UpNext

final class TranscriptSegmentBuilderTests: XCTestCase {

    private func makeLines(_ texts: [String], speaker: String? = "Host", start: TimeInterval = 0, step: TimeInterval = 2) -> [TranscriptSegmentSource] {
        texts.enumerated().map { index, text in
            let lineStart = start + Double(index) * step
            return TranscriptSegmentSource(
                speaker: speaker,
                text: text,
                startTime: lineStart,
                endTime: lineStart + step
            )
        }
    }

    func testShortLinesOfTheSameSpeakerAreMergedIntoOneParagraph() {
        let lines = makeLines(["So I was", "thinking about", "the new episode"])

        let segments = TranscriptSegmentBuilder.makeSegments(from: lines, options: .compact)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "So I was thinking about the new episode")
        XCTAssertEqual(segments[0].startTime, 0, accuracy: 0.001)
        XCTAssertEqual(segments[0].endTime ?? -1, 6, accuracy: 0.001)
        XCTAssertEqual(segments[0].lineIDs, lines.map(\.id))
    }

    func testSegmentKeepsIdentityOfItsFirstLine() {
        let lines = makeLines(["one", "two", "three"])

        let segments = TranscriptSegmentBuilder.makeSegments(from: lines, options: .compact)

        XCTAssertEqual(segments.first?.id, lines.first?.id)
    }

    func testSpeakerChangeStartsANewSegment() {
        let host = TranscriptSegmentSource(speaker: "Host", text: "How are you", startTime: 0, endTime: 2)
        let guest = TranscriptSegmentSource(speaker: "Guest", text: "Doing great", startTime: 2, endTime: 4)

        let segments = TranscriptSegmentBuilder.makeSegments(from: [host, guest], options: .compact)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].speaker, "Host")
        XCTAssertEqual(segments[1].speaker, "Guest")
    }

    func testSegmentsNeverExceedTheHardCharacterLimit() {
        let lines = makeLines(Array(repeating: "twenty characters ok", count: 40))

        let segments = TranscriptSegmentBuilder.makeSegments(from: lines, options: .compact)

        XCTAssertGreaterThan(segments.count, 1)
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.text.count, TranscriptSegmentBuilder.Options.compact.hardCharacterLimit)
        }
    }

    func testLongPauseStartsANewSegment() {
        let first = TranscriptSegmentSource(speaker: "Host", text: "And that was it", startTime: 0, endTime: 2)
        let second = TranscriptSegmentSource(speaker: "Host", text: "Welcome back", startTime: 30, endTime: 32)

        let segments = TranscriptSegmentBuilder.makeSegments(from: [first, second], options: .compact)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[1].text, "Welcome back")
    }

    func testSegmentBreaksAtSentenceBoundaryOnceItIsLongEnough() {
        var options = TranscriptSegmentBuilder.Options.compact
        options.softCharacterLimit = 10

        let lines = makeLines(["This is a full sentence.", "And this starts a new one"])

        let segments = TranscriptSegmentBuilder.makeSegments(from: lines, options: options)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "This is a full sentence.")
        XCTAssertEqual(segments[1].text, "And this starts a new one")
    }

    func testShortSentencesStillMergeBelowTheSoftLimit() {
        let lines = makeLines(["Yes.", "No.", "Maybe."])

        let segments = TranscriptSegmentBuilder.makeSegments(from: lines, options: .compact)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Yes. No. Maybe.")
    }

    func testSegmentsDoNotSpanMoreThanTheMaximumDuration() {
        var options = TranscriptSegmentBuilder.Options.compact
        options.maximumDuration = 5

        let lines = makeLines(["one", "two", "three", "four", "five"], step: 2)

        let segments = TranscriptSegmentBuilder.makeSegments(from: lines, options: options)

        XCTAssertGreaterThan(segments.count, 1)
        for segment in segments {
            guard let endTime = segment.endTime else { continue }
            XCTAssertLessThanOrEqual(endTime - segment.startTime, options.maximumDuration + 0.001)
        }
    }

    func testEveryLineEndsUpInExactlyOneSegment() {
        let lines = makeLines(Array(repeating: "some spoken words here", count: 25))

        let segments = TranscriptSegmentBuilder.makeSegments(from: lines, options: .full)
        let mappedIDs = segments.flatMap(\.lineIDs)

        XCTAssertEqual(mappedIDs, lines.map(\.id))
        XCTAssertEqual(Set(mappedIDs).count, lines.count)
    }

    func testUnsortedAndEmptyLinesAreHandled() {
        let later = TranscriptSegmentSource(speaker: "Host", text: "second", startTime: 4, endTime: 6)
        let blank = TranscriptSegmentSource(speaker: "Host", text: "   ", startTime: 2, endTime: 4)
        let first = TranscriptSegmentSource(speaker: "Host", text: "first", startTime: 0, endTime: 2)

        let segments = TranscriptSegmentBuilder.makeSegments(from: [later, blank, first], options: .compact)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "first second")
        XCTAssertEqual(segments[0].lineIDs, [first.id, later.id])
    }

    func testEmptyInputProducesNoSegments() {
        XCTAssertTrue(TranscriptSegmentBuilder.makeSegments(from: [] as [TranscriptSegmentSource], options: .compact).isEmpty)
    }

    func testSingleLineLongerThanTheHardLimitIsKeptIntact() {
        let text = String(repeating: "word ", count: 200).trimmingCharacters(in: .whitespaces)
        let line = TranscriptSegmentSource(speaker: nil, text: text, startTime: 0, endTime: 30)

        let segments = TranscriptSegmentBuilder.makeSegments(from: [line], options: .compact)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, text)
    }

    func testSentenceDetectionIgnoresTrailingQuotesAndBrackets() {
        XCTAssertTrue(TranscriptSegmentBuilder.endsSentence("He said \"hello.\""))
        XCTAssertTrue(TranscriptSegmentBuilder.endsSentence("Really?  "))
        XCTAssertFalse(TranscriptSegmentBuilder.endsSentence("and then we"))
        XCTAssertFalse(TranscriptSegmentBuilder.endsSentence(""))
    }
}
