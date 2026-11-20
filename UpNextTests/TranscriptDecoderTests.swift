import XCTest
import SwiftData
import Speech
import CoreMedia
@testable import UpNext

final class TranscriptDecoderTests: XCTestCase {
    func testSpeechTimedRunsKeepTextAndAudioGaps() throws {
        var text = AttributedString("👋 hello, friend!")
        let hello = try XCTUnwrap(text.range(of: "👋 hello,"))
        let friend = try XCTUnwrap(text.range(of: "friend!"))
        text[hello].audioTimeRange = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), duration: CMTime(seconds: 0.5, preferredTimescale: 600))
        text[friend].audioTimeRange = CMTimeRange(start: CMTime(seconds: 3, preferredTimescale: 600), duration: CMTime(seconds: 1, preferredTimescale: 600))
        let result = AITranscripts.timedResult(range: CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600)), text: text)
        XCTAssertEqual(result.text, "👋 hello, friend!")
        XCTAssertEqual(result.timedSpans.map(\.startTime), [1, 3])
        XCTAssertEqual(result.timedSpans.map(\.endTime), [1.5, 4])
        XCTAssertEqual(result.timedSpans.map { (result.text as NSString).substring(with: NSRange(location: $0.location, length: $0.length)) }, ["👋 hello,", "friend!"])
    }

    func testOutOfOrderSpeechTimingFallsBackToCueWithoutChangingText() throws {
        var text = AttributedString("first second")
        let first = try XCTUnwrap(text.range(of: "first"))
        let second = try XCTUnwrap(text.range(of: "second"))
        text[first].audioTimeRange = CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 600), duration: CMTime(seconds: 0.5, preferredTimescale: 600))
        text[second].audioTimeRange = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), duration: CMTime(seconds: 0.5, preferredTimescale: 600))

        let result = AITranscripts.timedResult(
            range: CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600)),
            text: text
        )

        XCTAssertEqual(result.text, "first second")
        XCTAssertTrue(result.timedSpans.isEmpty)
    }
    func testWebVTTKeepsMultilineTextAndInlineTimingWithUnicodeOffsets() throws {
        let decoder = TranscriptDecoder("""
        WEBVTT

        cue-id
        00:00:01.000 --> 00:00:05.000 align:start
        <v Alex>Hi 👋 <00:00:02.000>there,
        <00:00:03.500>friend!</v>

        00:00:06.000 --> 00:00:07.000
        Another cue
        """)
        XCTAssertEqual(decoder.transcriptLines.count, 2)
        let cue = try XCTUnwrap(decoder.transcriptLines.first)
        XCTAssertEqual(cue.speaker, "Alex")
        XCTAssertEqual(cue.text, "Hi 👋 there,\nfriend!")
        XCTAssertEqual(cue.timedSpans.map(\.startTime), [1, 2, 3.5])
        XCTAssertEqual(cue.timedSpans.map(\.endTime), [2, 3.5, 5])
        XCTAssertEqual(cue.timedSpans.map { (cue.text as NSString).substring(with: NSRange(location: $0.location, length: $0.length)) },
                       ["Hi 👋 ", "there,\n", "friend!"])
        XCTAssertTrue(decoder.transcriptLines[1].timedSpans.isEmpty)
    }

    func testInvalidInlineTimingFallsBackToCueWithoutLosingText() throws {
        let decoder = TranscriptDecoder("""
        WEBVTT

        00:00:01.000 --> 00:00:04.000
        One <00:00:03.000>two <00:00:02.000>three
        """)
        let cue = try XCTUnwrap(decoder.transcriptLines.first)
        XCTAssertEqual(cue.text, "One two three")
        XCTAssertTrue(cue.timedSpans.isEmpty)
    }

    @MainActor
    func testTimedSpansSurviveStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Library.sqlite")
        let spans = [TranscriptTimedSpan(location: 0, length: 5, startTime: 1, endTime: 2)]
        do {
            let container = try ModelContainerManager.makeLegacyContainer(storageURL: url)
            let context = ModelContext(container)
            context.insert(TranscriptLineAndTime(text: "Hello", startTime: 1, endTime: 2, timedSpans: spans))
            try context.save()
        }
        let reopened = try ModelContainerManager.makeLegacyContainer(storageURL: url)
        let lines = try ModelContext(reopened).fetch(FetchDescriptor<TranscriptLineAndTime>())
        XCTAssertEqual(lines.first?.timedSpans, spans)
    }
}
