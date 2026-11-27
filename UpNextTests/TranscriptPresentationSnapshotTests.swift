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

    // MARK: #493 canonical document matrix

    func testTimingQualityMatrixAcrossDocumentKinds() throws {
        let word = [TranscriptTimedSpan(location: 0, length: 5, startTime: 1, endTime: 1.4)]
        func quality(_ lines: [TranscriptSegmentSource]) -> TranscriptPresentationSnapshot.TimingQuality {
            TranscriptPresentationSnapshot.resolve(
                document: TranscriptDocumentSnapshot.resolve(episodeID: "ep", storedLines: lines)).timingQuality
        }
        // Publisher VTT/SRT with inline word timing, cue-only, and untimed text.
        XCTAssertEqual(quality([line("Hello there.", .publisher, start: 1, end: 3, spans: word)]), .nativeWords)
        XCTAssertEqual(quality([line("Hello there.", .publisher, start: 1, end: 3)]), .rawCues)
        XCTAssertEqual(quality([line("Hello there.", .publisher)]), .unavailable, "static fallback")
        // Cue-level spans identify the caption but never claim word precision.
        XCTAssertEqual(quality([line("Hello there.", .publisher, start: 1, end: 3,
            spans: [.init(location: 0, length: 12, startTime: 1, endTime: 3, cueLevel: true)])]), .rawCues)
        // No publisher transcript: a full local transcript is the document.
        let local = try XCTUnwrap(TranscriptDocumentSnapshot.resolve(episodeID: "ep", storedLines: [
            line("hello there", .localAI, start: 1, end: 3, spans: word)
        ]))
        XCTAssertEqual(local.source, .generated)
        XCTAssertEqual(TranscriptPresentationSnapshot.resolve(document: local).timingQuality, .nativeWords)
        // No stored document: partial live recognition is shown with its own timing.
        let live = TranscriptPresentationSnapshot.resolve(document: nil, livePartial: [
            line("hello", .localAI, start: 1, end: 2, spans: word)
        ])
        XCTAssertNil(live.document)
        XCTAssertEqual(live.timingQuality, .nativeWords)
        XCTAssertEqual(TranscriptPresentationSnapshot.resolve(document: nil, livePartial: [
            line("hello", .localAI, start: 1, end: 2)
        ]).timingQuality, .rawCues)
        XCTAssertEqual(TranscriptPresentationSnapshot.resolve(document: nil).segments, [])
        XCTAssertEqual(TranscriptPresentationSnapshot.resolve(document: nil).timingQuality, .unavailable)
    }

    func testDerivedTimingNeverAppliesToGeneratedTextOrUnknownMedia() throws {
        let words: [TranscriptTimedSpan] = [.init(location: 0, length: 5, startTime: 3, endTime: 3.4)]
        let timeline = try XCTUnwrap(TranscriptSynchronizationTimeline(anchors: [
            .init(transcriptTime: 0, audioTime: 2, confidence: 1),
            .init(transcriptTime: 4, audioTime: 6, confidence: 1)
        ]))
        for source in [CachedTranscriptSource.localAI, .ai] {
            let generated = line("hello there", source, start: 0, end: 2)
            let document = try XCTUnwrap(TranscriptDocumentSnapshot.resolve(episodeID: "ep", storedLines: [generated]))
            let evidence = PublisherTranscriptTimingEvidence(episodeID: "ep", mediaFingerprint: "media",
                transcriptRevision: try XCTUnwrap(document.timingRevision), timeline: timeline,
                wordsByLine: [generated.id: words])
            let resolved = TranscriptPresentationSnapshot.resolve(document: document, mediaFingerprint: "media", evidence: evidence)
            XCTAssertNil(resolved.timeline, "generated text is already on the audio clock")
            XCTAssertTrue(resolved.enhancedWordsBySegment.isEmpty)
            XCTAssertEqual(resolved.timingQuality, .rawCues)
        }
        let publisher = line("hello there", .publisher, start: 0, end: 2)
        let document = try XCTUnwrap(TranscriptDocumentSnapshot.resolve(episodeID: "ep", storedLines: [publisher]))
        for fingerprint in [nil, ""] as [String?] {
            let evidence = PublisherTranscriptTimingEvidence(episodeID: "ep", mediaFingerprint: fingerprint ?? "",
                transcriptRevision: try XCTUnwrap(document.timingRevision), timeline: timeline,
                wordsByLine: [publisher.id: words])
            let resolved = TranscriptPresentationSnapshot.resolve(document: document, mediaFingerprint: fingerprint, evidence: evidence)
            XCTAssertNil(resolved.timeline)
            XCTAssertTrue(resolved.enhancedWordsBySegment.isEmpty)
        }
    }

    func testDocumentIdentityIsDeterministicAndKeepsPublisherWordingSpeakersAndPunctuation() throws {
        let lines = [
            TranscriptSegmentSource(speaker: "ANNA", text: "[Music] Welcome back—it’s “Up Next”!", startTime: 0, endTime: 2,
                                    sourceRawValue: CachedTranscriptSource.publisher.rawValue),
            TranscriptSegmentSource(speaker: "Ben", text: "BEN: $20, 3½ hours… really?", startTime: 2, endTime: 4,
                                    sourceRawValue: CachedTranscriptSource.publisher.rawValue)
        ]
        let first = try XCTUnwrap(TranscriptDocumentSnapshot.resolve(episodeID: "ep", storedLines: lines))
        let again = try XCTUnwrap(TranscriptDocumentSnapshot.resolve(episodeID: "ep", storedLines: lines.reversed()))
        XCTAssertEqual(first, again, "input order does not change the canonical document")
        XCTAssertEqual(first.segments.map(\.id), lines.map(\.id))
        XCTAssertEqual(first.segments.map(\.text), lines.map(\.text), "wording and punctuation are untouched")
        XCTAssertEqual(first.segments.map(\.speaker), ["ANNA", "Ben"])

        // A wording revision is a new timing revision; derived timing for it is stale.
        let revised = [lines[0], TranscriptSegmentSource(id: lines[1].id, speaker: "Ben", text: "BEN: $20, 3½ hours… really!",
            startTime: 2, endTime: 4, sourceRawValue: CachedTranscriptSource.publisher.rawValue)]
        let changed = try XCTUnwrap(TranscriptDocumentSnapshot.resolve(episodeID: "ep", storedLines: revised))
        XCTAssertNotEqual(first.timingRevision, changed.timingRevision)
        XCTAssertEqual(first.segments.map(\.id), changed.segments.map(\.id))
    }

    /// Search and copy read the prepared rows, so a timing upgrade cannot change results.
    func testSearchMatchesPreparedRowsIdenticallyAcrossTimingUpgrade() {
        let ids = [UUID(), UUID()]
        func lines(words: Bool) -> [TranscriptSegmentSource] {
            [("Straße und Café.", 0.0), ("Something else entirely.", 10.0)].enumerated().map { index, entry in
                TranscriptSegmentSource(id: ids[index], speaker: "Host", text: entry.0, startTime: entry.1,
                    endTime: entry.1 + 2, sourceRawValue: CachedTranscriptSource.publisher.rawValue,
                    timedSpans: words ? [.init(location: 0, length: 3, startTime: entry.1, endTime: entry.1 + 0.3)] : [])
            }
        }
        let raw = TranscriptPreparedSnapshot.make(from: lines(words: false))
        let worded = TranscriptPreparedSnapshot.make(from: lines(words: true))
        for query in ["strasse", "CAFE", " café ", "entirely", "missing", ""] {
            let before = raw.segments.filter { TranscriptSearchText.matches($0.text, query: query) }.map(\.id)
            let after = worded.segments.filter { TranscriptSearchText.matches($0.text, query: query) }.map(\.id)
            XCTAssertEqual(before, after, query)
        }
        XCTAssertEqual(raw.segments.filter { TranscriptSearchText.matches($0.text, query: "strasse") }.map(\.id), [ids[0]])
        XCTAssertTrue(raw.segments.filter { TranscriptSearchText.matches($0.text, query: "  ") }.isEmpty)
    }

    // MARK: #493 tracker lookup on stable IDs

    @MainActor
    func testTrackerLookupResolvesStableSegmentIDsAndWordRanges() {
        let first = TranscriptSegmentSource(text: "Hello there.", startTime: 10, endTime: 12,
            timedSpans: [.init(location: 6, length: 5, startTime: 11, endTime: 11.5)])
        let second = TranscriptSegmentSource(text: "After a pause.", startTime: 20, endTime: 22,
            timedSpans: [.init(location: 0, length: 14, startTime: 20, endTime: 22, cueLevel: true)])
        let open = TranscriptSegmentSource(text: "Open ended", startTime: 30)
        let segments = TranscriptSegmentBuilder.makeSegments(from: [open, second, first], options: .full)
        XCTAssertEqual(segments.map(\.id), [first.id, second.id, open.id])
        typealias Tracker = TranscriptPlaybackTracker
        XCTAssertNil(Tracker.lookup(segments: segments, at: 9.9), "before the first caption")
        XCTAssertEqual(Tracker.lookup(segments: segments, at: 10), .init(segmentID: first.id, location: nil, length: nil))
        XCTAssertEqual(Tracker.lookup(segments: segments, at: 11.2), .init(segmentID: first.id, location: 6, length: 5))
        XCTAssertNil(Tracker.lookup(segments: segments, at: 15), "a pause has no active caption")
        XCTAssertEqual(Tracker.lookup(segments: segments, at: 21), .init(segmentID: second.id, location: nil, length: nil),
                       "cue-level timing highlights the row, not a word")
        XCTAssertEqual(Tracker.lookup(segments: segments, at: 5_000)?.segmentID, open.id)
        XCTAssertNil(Tracker.lookup(segments: segments, at: .nan))
        XCTAssertNil(Tracker.lookup(segments: [], at: 10))
    }
}
