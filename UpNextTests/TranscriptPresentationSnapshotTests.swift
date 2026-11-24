import XCTest
@testable import UpNext

final class TranscriptPresentationSnapshotTests: XCTestCase {
    private func line(_ text: String, _ source: CachedTranscriptSource?, start: Double = 0,
                      end: Double? = nil, spans: [TranscriptTimedSpan] = []) -> TranscriptSegmentSource {
        TranscriptSegmentSource(speaker: "Host", text: text, startTime: start, endTime: end,
                                sourceRawValue: source?.rawValue, timedSpans: spans)
    }

    func testFullDocumentPrecedenceAndLiveFallback() throws {
        let publisher = line("Hello, world!", .publisher)
        let generated = line("hello whirl", .localAI)
        let legacy = line("Old transcript", nil)
        let partial = [line("hello", .localAI)]
        let document = try XCTUnwrap(TranscriptDocumentSnapshot.resolve(
            episodeID: "ep", storedLines: [generated, publisher]))
        let full = TranscriptPresentationSnapshot.resolve(document: document, livePartial: partial)
        XCTAssertEqual(full.document?.lines, [publisher])
        XCTAssertEqual(full.segments.map(\.text), ["Hello, world!"])
        XCTAssertEqual(full.timingQuality, .unavailable)
        for source in [CachedTranscriptSource.ai, .localAI] {
            let local = line("Generated", source)
            XCTAssertEqual(TranscriptDocumentSnapshot.resolve(episodeID: "ep", storedLines: [
                line(" \n", .publisher), local, legacy
            ])?.lines, [local])
        }
        XCTAssertEqual(TranscriptDocumentSnapshot.resolve(episodeID: "ep", storedLines: [legacy])?.source,
                       .legacyUnknown)
        XCTAssertNil(TranscriptDocumentSnapshot.resolve(episodeID: "ep", storedLines: []))
        let live = TranscriptPresentationSnapshot.resolve(document: nil, livePartial: partial)
        XCTAssertNil(live.document)
        XCTAssertEqual(live.segments.map(\.text), ["hello"])
    }

    func testDerivedAudioTimingRebasesOntoExactPublisherTextAndExpires() throws {
        let first = line("First.", .publisher, end: 1)
        let second = line("  👋 there!", .publisher, start: 1, end: 2)
        let document = try XCTUnwrap(TranscriptDocumentSnapshot.resolve(episodeID: "ep", storedLines: [second, first]))
        let timeline = try XCTUnwrap(TranscriptSynchronizationTimeline(anchors: [
            .init(transcriptTime: 0, audioTime: 20, confidence: 1),
            .init(transcriptTime: 2, audioTime: 22, confidence: 1)
        ]))
        let evidence = PublisherTranscriptTimingEvidence(episodeID: "ep", mediaFingerprint: "media",
            transcriptRevision: try XCTUnwrap(document.timingRevision), timeline: timeline,
            wordsByLine: [second.id: [
                .init(location: 2, length: 2, startTime: 21, endTime: 21.3),
                .init(location: 3, length: 1, startTime: 21, endTime: 21.3) // Inside the emoji.
            ]])
        let enriched = TranscriptPresentationSnapshot.resolve(document: document, mediaFingerprint: "media", evidence: evidence)
        XCTAssertEqual(enriched.document, document)
        XCTAssertEqual(enriched.timeline, timeline)
        XCTAssertEqual(enriched.timingQuality, .enhancedWords)
        let segment = try XCTUnwrap(enriched.segments.first)
        XCTAssertEqual(segment.text, "First. 👋 there!")
        XCTAssertEqual(enriched.enhancedWordsBySegment[segment.id], [
            .init(location: 7, length: 2, startTime: 21, endTime: 21.3)
        ])
        let revised = TranscriptSegmentSource(id: second.id, speaker: second.speaker, text: "Revised.",
            startTime: second.startTime, endTime: second.endTime, sourceRawValue: second.sourceRawValue)
        let changed = try XCTUnwrap(TranscriptDocumentSnapshot.resolve(episodeID: "ep", storedLines: [first, revised]))
        let otherEpisode = try XCTUnwrap(TranscriptDocumentSnapshot.resolve(episodeID: "other", storedLines: document.lines))
        for (current, media) in [(document, "replaced"), (changed, "media"), (otherEpisode, "media")] {
            let fallback = TranscriptPresentationSnapshot.resolve(document: current, mediaFingerprint: media, evidence: evidence)
            XCTAssertEqual(fallback.document, current)
            XCTAssertTrue(fallback.enhancedWordsBySegment.isEmpty)
            XCTAssertNil(fallback.timeline)
            XCTAssertEqual(fallback.timingQuality, .rawCues)
        }
    }

    func testWordPrecisionRequiresUsableNativeSpansOrVerifiedEvidence() throws {
        let word = TranscriptTimedSpan(location: 0, length: 5, startTime: 0, endTime: 0.4)
        let valid = line("hello", .publisher, end: 1, spans: [word])
        let full = TranscriptDocumentSnapshot.resolve(episodeID: "ep", storedLines: [valid])
        XCTAssertEqual(TranscriptPresentationSnapshot.resolve(document: full).timingQuality, .nativeWords)
        let raw = try XCTUnwrap(TranscriptDocumentSnapshot.resolve(episodeID: "ep", storedLines: [
            line("hello", .publisher, end: 1)
        ]))
        let timeline = try XCTUnwrap(TranscriptSynchronizationTimeline(anchors: [
            .init(transcriptTime: 0, audioTime: 2, confidence: 1),
            .init(transcriptTime: 1, audioTime: 3, confidence: 1)
        ]))
        let evidence = PublisherTranscriptTimingEvidence(episodeID: "ep", mediaFingerprint: "file",
            transcriptRevision: try XCTUnwrap(raw.timingRevision), timeline: timeline, wordsByLine: [:])
        let coarse = TranscriptPresentationSnapshot.resolve(document: raw, mediaFingerprint: "file", evidence: evidence)
        XCTAssertEqual(coarse.timingQuality, .verifiedCues)
        XCTAssertTrue(coarse.enhancedWordsBySegment.isEmpty)
    }
}
