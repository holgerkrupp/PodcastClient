import XCTest
@testable import UpNext

final class TranscriptSynchronizationTests: XCTestCase {
    func testIdentityTimelinePreservesZeroOffset() throws {
        let timeline = try XCTUnwrap(TranscriptSynchronizationTimeline(anchors: [
            .init(transcriptTime: 0, audioTime: 0, confidence: 1),
            .init(transcriptTime: 120, audioTime: 120, confidence: 0.95)
        ]))
        XCTAssertEqual(timeline.audioTime(forTranscriptTime: 42) ?? -1, 42, accuracy: 0.001)
        XCTAssertEqual(timeline.transcriptTime(forAudioTime: 42) ?? -1, 42, accuracy: 0.001)
    }

    func testOneInsertionCreatesPiecewiseCumulativeCorrection() throws {
        let timeline = try XCTUnwrap(TranscriptSynchronizationTimeline(anchors: [
            .init(transcriptTime: 60, audioTime: 60, confidence: 0.95),
            .init(transcriptTime: 120, audioTime: 195, confidence: 0.95),
            .init(transcriptTime: 180, audioTime: 255, confidence: 0.95)
        ]))
        XCTAssertEqual(timeline.audioTime(forTranscriptTime: 80) ?? -1, 105, accuracy: 0.001)
        XCTAssertEqual(timeline.transcriptTime(forAudioTime: 225) ?? -1, 150, accuracy: 0.001)
    }

    func testTwoInsertionsAccumulateSeparateCorrections() throws {
        let timeline = try XCTUnwrap(TranscriptSynchronizationTimeline(anchors: [
            .init(transcriptTime: 30, audioTime: 30, confidence: 0.96),
            .init(transcriptTime: 90, audioTime: 120, confidence: 0.94),
            .init(transcriptTime: 150, audioTime: 210, confidence: 0.93),
            .init(transcriptTime: 210, audioTime: 285, confidence: 0.95)
        ]))
        XCTAssertEqual(timeline.audioTime(forTranscriptTime: 180) ?? -1, 247.5, accuracy: 0.001)
        XCTAssertEqual(timeline.audioTime(forTranscriptTime: 210) ?? -1, 285, accuracy: 0.001)
    }

    func testConfirmedInsertionGapHasNoActiveCaption() throws {
        let timeline = try XCTUnwrap(TranscriptSynchronizationTimeline(
            anchors: [
                .init(transcriptTime: 60, audioTime: 60, confidence: 0.95),
                .init(transcriptTime: 120, audioTime: 195, confidence: 0.95)
            ],
            gaps: [.init(audioStart: 60, audioEnd: 135, transcriptTime: 60)]
        ))
        XCTAssertNil(timeline.transcriptTime(forAudioTime: 90))
        XCTAssertEqual(timeline.transcriptTime(forAudioTime: 165) ?? -1, 106.666_667, accuracy: 0.001)
    }

    func testRejectsSingleContradictoryOrMalformedAnchors() {
        XCTAssertNil(TranscriptSynchronizationTimeline(anchors: [
            .init(transcriptTime: 60, audioTime: 60, confidence: 0.9)
        ]))
        XCTAssertNil(TranscriptSynchronizationTimeline(anchors: [
            .init(transcriptTime: 60, audioTime: 90, confidence: 0.9),
            .init(transcriptTime: 120, audioTime: 80, confidence: 0.9)
        ]))
        XCTAssertNil(TranscriptSynchronizationTimeline(anchors: [
            .init(transcriptTime: 60, audioTime: .infinity, confidence: 0.9),
            .init(transcriptTime: 120, audioTime: 130, confidence: 0.9)
        ]))
    }

    func testMatcherRequiresPublisherSourceAndRejectsAmbiguousCommonPhrases() {
        let publisher = TranscriptAlignmentCandidate(
            transcriptTime: 42,
            text: "The remarkable discovery changed everything in the laboratory",
            source: .publisher
        )
        let localAI = TranscriptAlignmentCandidate(
            transcriptTime: 42,
            text: publisher.text,
            source: .localAI
        )
        XCTAssertNotNil(TranscriptAlignmentMatcher.match(
            recognizedText: "A remarkable discovery changed everything in the laboratory",
            actualAudioTime: 47,
            candidates: [publisher],
            expectedTranscriptTime: 42
        ))
        XCTAssertNil(TranscriptAlignmentMatcher.match(
            recognizedText: "A remarkable discovery changed everything in the laboratory",
            actualAudioTime: 47,
            candidates: [localAI],
            expectedTranscriptTime: 42
        ))
        XCTAssertNil(TranscriptAlignmentMatcher.match(
            recognizedText: "and then what was that",
            actualAudioTime: 47,
            candidates: [publisher],
            expectedTranscriptTime: 42
        ))
    }
}
