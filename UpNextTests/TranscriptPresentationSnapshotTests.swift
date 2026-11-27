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

    // #487: raw cue -> verified alignment -> word timing must refine highlighting in place.
    @MainActor
    func testTimingUpgradeKeepsSegmentIdentityTextAndOrder() throws {
        let ids = [UUID(), UUID(), UUID()]
        func lines(words: Bool) -> [TranscriptSegmentSource] {
            [("Hello there.", 0.0, 1.0), ("Second line.", 1.0, 2.0), ("Third.", 10.0, 11.0)]
                .enumerated().map { index, entry in
                    TranscriptSegmentSource(id: ids[index], speaker: "Host", text: entry.0,
                        startTime: entry.1, endTime: entry.2, sourceRawValue: CachedTranscriptSource.publisher.rawValue,
                        timedSpans: words ? [.init(location: 0, length: 5, startTime: entry.1, endTime: entry.1 + 0.4)] : [])
                }
        }
        let raw = TranscriptPreparedSnapshot.make(from: lines(words: false), sourcesAreSorted: true)
        let worded = TranscriptPreparedSnapshot.make(from: lines(words: true), sourcesAreSorted: true)
        XCTAssertEqual(raw.presentation.timingQuality, .rawCues)
        XCTAssertEqual(worded.presentation.timingQuality, .nativeWords)
        XCTAssertNotEqual(raw, worded)
        XCTAssertTrue(raw.hasSameDocumentLayout(as: worded))
        XCTAssertEqual(raw.segments.map(\.id), worded.segments.map(\.id))
        XCTAssertEqual(raw.segments.map(\.text), worded.segments.map(\.text))
        XCTAssertEqual(raw.segments.map(\.lineIDs), worded.segments.map(\.lineIDs))
        XCTAssertEqual(raw.segments.first?.id, ids[0])

        // Verified alignment and matched words are an overlay keyed by the same segment IDs.
        let document = try XCTUnwrap(raw.presentation.document)
        let timeline = try XCTUnwrap(TranscriptSynchronizationTimeline(anchors: [
            .init(transcriptTime: 0, audioTime: 5, confidence: 1),
            .init(transcriptTime: 11, audioTime: 16, confidence: 1)
        ]))
        let evidence = PublisherTranscriptTimingEvidence(episodeID: "", mediaFingerprint: "media",
            transcriptRevision: try XCTUnwrap(document.timingRevision), timeline: timeline,
            wordsByLine: [ids[2]: [.init(location: 0, length: 5, startTime: 15, endTime: 15.4)]])
        let aligned = TranscriptPresentationSnapshot.resolve(document: document, mediaFingerprint: "media", evidence: evidence)
        XCTAssertEqual(aligned.segments, raw.segments)
        XCTAssertEqual(aligned.timingQuality, .enhancedWords)
        XCTAssertEqual(Set(aligned.enhancedWordsBySegment.keys).subtracting(raw.segments.map(\.id)), [])

        // The tracker keeps the same active row and only gains word precision.
        let before = TranscriptPlaybackTracker.lookup(segments: raw.segments, at: 0.2)
        let after = TranscriptPlaybackTracker.lookup(segments: worded.segments, at: 0.2)
        XCTAssertEqual(before?.segmentID, after?.segmentID)
        XCTAssertNil(before?.location)
        XCTAssertEqual(after?.location, 0)
    }

    func testLayoutChangesWhenTextOrLineIdentityChanges() {
        let line = TranscriptSegmentSource(text: "Hello.", startTime: 0, endTime: 1,
                                           sourceRawValue: CachedTranscriptSource.publisher.rawValue)
        let base = TranscriptPreparedSnapshot.make(from: [line])
        let edited = TranscriptPreparedSnapshot.make(from: [TranscriptSegmentSource(id: line.id, text: "Hello!",
            startTime: 0, endTime: 1, sourceRawValue: line.sourceRawValue)])
        let replaced = TranscriptPreparedSnapshot.make(from: [TranscriptSegmentSource(text: "Hello.",
            startTime: 0, endTime: 1, sourceRawValue: line.sourceRawValue)])
        XCTAssertTrue(base.hasSameDocumentLayout(as: base))
        XCTAssertFalse(base.hasSameDocumentLayout(as: edited))
        XCTAssertFalse(base.hasSameDocumentLayout(as: replaced))
    }

    func testPublisherTextIsNeverReplacedByBetterTimedLocalASR() {
        let publisher = TranscriptSegmentSource(text: "Welcome to Up Next.", startTime: 0, endTime: 3,
                                                sourceRawValue: CachedTranscriptSource.publisher.rawValue)
        let asr = [CachedTranscriptSource.ai, .localAI].map { source in
            TranscriptSegmentSource(text: "welcome to a pinnacle", startTime: 0, endTime: 3,
                sourceRawValue: source.rawValue,
                timedSpans: [.init(location: 0, length: 7, startTime: 0, endTime: 0.5)])
        }
        let snapshot = TranscriptPreparedSnapshot.make(from: asr + [publisher])
        XCTAssertEqual(snapshot.presentation.document?.source, .publisher)
        XCTAssertEqual(snapshot.segments.map(\.text), ["Welcome to Up Next."])
        XCTAssertEqual(snapshot.segments.flatMap(\.lineIDs), [publisher.id])
    }
}
