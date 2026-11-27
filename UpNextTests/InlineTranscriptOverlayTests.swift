import XCTest
@testable import UpNext

/// Inline transcript overlay (#520): incremental live captions, bounded caption
/// wrapping and the display-only overlay state.
final class InlineTranscriptOverlayTests: XCTestCase {

    // Groups of four cues separated by a pause longer than the compact
    // maximum silence, so every group becomes its own compact segment.
    private func cue(_ index: Int, text: String? = nil, id: UUID = UUID()) -> LiveTranscriptState.Cue {
        let start = Double(index) * 2 + Double(index / 4) * 3
        return LiveTranscriptState.Cue(
            id: id,
            text: text ?? "Cue \(index) is short.",
            start: start,
            end: start + 1.5,
            spans: []
        )
    }

    private func sources(_ cues: [LiveTranscriptState.Cue]) -> [TranscriptSegmentSource] {
        LiveTranscriptController.mergedSources(final: cues, tentative: [])
    }

    private let layout = CaptionLayout(width: 320, height: 80, fontSize: 17)

    // MARK: Incremental segments

    func testAppendingLiveCuesReusesClosedSegmentsAndMatchesFullRebuild() {
        var accumulator = InlineSegmentAccumulator()
        var cues: [LiveTranscriptState.Cue] = []

        for index in 0..<200 {
            cues.append(cue(index))
            let previous = accumulator.segments
            let update = accumulator.update(with: sources(cues))

            XCTAssertTrue(update.changed)
            // Only the trailing segment may be regrouped for an appended cue.
            XCTAssertGreaterThanOrEqual(update.reusedSegments, max(0, previous.count - 1))
            XCTAssertLessThanOrEqual(update.rebuiltSegments, 2)
            XCTAssertEqual(Array(accumulator.segments.prefix(update.reusedSegments)),
                           Array(previous.prefix(update.reusedSegments)))
            XCTAssertEqual(accumulator.segments,
                           TranscriptSegmentBuilder.makeSegments(fromSorted: sources(cues), options: .compact))
        }
        XCTAssertEqual(accumulator.segments.count, 50)
    }

    func testUnchangedSourcesAreANoOp() {
        var accumulator = InlineSegmentAccumulator()
        let cues = (0..<12).map { cue($0) }
        accumulator.update(with: sources(cues))

        let update = accumulator.update(with: sources(cues))

        XCTAssertFalse(update.changed)
        XCTAssertEqual(update.rebuiltSegments, 0)
    }

    func testRevisingTrailingCueRegroupsOnlyTheTail() {
        var accumulator = InlineSegmentAccumulator()
        var cues = (0..<40).map { cue($0) }
        accumulator.update(with: sources(cues))
        let before = accumulator.segments

        let last = cues.count - 1
        cues[last] = cue(last, text: "A revised final caption.", id: cues[last].id)
        let update = accumulator.update(with: sources(cues))

        XCTAssertEqual(update.reusedSegments, before.count - 1)
        XCTAssertEqual(update.rebuiltSegments, 1)
        XCTAssertEqual(accumulator.segments.last?.id, before.last?.id, "segment identity is stable")
        XCTAssertEqual(accumulator.segments,
                       TranscriptSegmentBuilder.makeSegments(fromSorted: sources(cues), options: .compact))
    }

    func testInsertingEarlierCueAfterSeekMatchesFullRebuild() {
        var accumulator = InlineSegmentAccumulator()
        var cues = (0..<40).map { cue($0) }
        cues.remove(at: 9)
        accumulator.update(with: sources(cues))

        cues.insert(cue(9), at: 9)
        let update = accumulator.update(with: sources(cues))

        XCTAssertGreaterThanOrEqual(update.reusedSegments, 1)
        XCTAssertEqual(accumulator.segments,
                       TranscriptSegmentBuilder.makeSegments(fromSorted: sources(cues), options: .compact))
    }

    func testSpeakersAreTrackedIncrementally() {
        var accumulator = InlineSegmentAccumulator()
        let lines = [
            TranscriptSegmentSource(speaker: "Dave", text: "Hello.", startTime: 0, endTime: 1),
            TranscriptSegmentSource(speaker: "Ann", text: "Hi.", startTime: 1, endTime: 2)
        ]
        accumulator.update(with: lines)
        XCTAssertEqual(accumulator.speakers, ["Ann", "Dave"])

        accumulator.update(with: Array(lines.prefix(1)))
        XCTAssertEqual(accumulator.speakers, ["Dave"])
    }

    // MARK: Bounded caption window

    func testWindowWrapsOnlyNearbySegmentsAndMatchesFullCaptions() {
        var accumulator = InlineSegmentAccumulator()
        accumulator.update(with: sources((0..<2000).map { cue($0) }))
        let segments = accumulator.segments
        XCTAssertEqual(segments.count, 500)

        var window = InlineCaptionWindow()
        window.materialize(segments: segments, center: 250, radius: 3, layout: layout)

        XCTAssertEqual(window.wrappedSegmentCount, 7, "a long transcript must not be wrapped in full")
        XCTAssertEqual(window.range, 247..<254)
        let reference = InlineCaptionBuilder.makeCaptions(from: Array(segments[247..<255]), layout: layout)
        let windowIDs = Set(segments[247..<254].map(\.id))
        // Captions keep their source segment's line IDs; the first is the segment ID.
        XCTAssertEqual(window.captions, reference.filter { caption in
            caption.segment.lineIDs.first.map(windowIDs.contains) ?? false
        })
        XCTAssertEqual(window.captionSegments, window.captions.map(\.segment))
    }

    func testAppendingLiveCueRewrapsOnlyTheTrailingSegment() {
        var accumulator = InlineSegmentAccumulator()
        var cues = (0..<40).map { cue($0) }
        accumulator.update(with: sources(cues))
        var window = InlineCaptionWindow()
        window.materialize(segments: accumulator.segments, center: accumulator.segments.count - 1,
                           radius: InlineCaptionWindow.browseRadius, layout: layout)
        let wrappedBefore = window.wrappedSegmentCount

        cues.append(cue(40))
        accumulator.update(with: sources(cues))
        window.materialize(segments: accumulator.segments, center: accumulator.segments.count - 1,
                           radius: InlineCaptionWindow.browseRadius, layout: layout)

        // The new segment plus its predecessor, whose successor start changed.
        XCTAssertLessThanOrEqual(window.wrappedSegmentCount - wrappedBefore, 2)
        let lower = window.range.lowerBound
        let reference = InlineCaptionBuilder.makeCaptions(from: Array(accumulator.segments[lower...]), layout: layout)
        XCTAssertEqual(window.captions, reference)
    }

    func testLayoutChangeRewrapsTheWindow() {
        var accumulator = InlineSegmentAccumulator()
        accumulator.update(with: sources((0..<20).map { cue($0) }))
        var window = InlineCaptionWindow()
        window.materialize(segments: accumulator.segments, center: 0, radius: 20, layout: layout)
        let narrow = CaptionLayout(width: 160, height: 80, fontSize: 17)

        window.materialize(segments: accumulator.segments, center: 0, radius: 20, layout: narrow)

        XCTAssertEqual(window.wrappedSegmentCount, 10)
        XCTAssertEqual(window.captions, InlineCaptionBuilder.makeCaptions(from: accumulator.segments, layout: narrow))
    }

    func testSpeakerHeadersMatchTurnChanges() {
        var accumulator = InlineSegmentAccumulator()
        accumulator.update(with: [
            TranscriptSegmentSource(speaker: "Dave", text: "Hello there.", startTime: 0, endTime: 1),
            TranscriptSegmentSource(speaker: "Ann", text: "Hi.", startTime: 1, endTime: 2),
            TranscriptSegmentSource(speaker: "Ann", text: "Long pause before this.", startTime: 10, endTime: 11)
        ])
        var window = InlineCaptionWindow()
        window.materialize(segments: accumulator.segments, center: 0, radius: 10, layout: layout)

        XCTAssertEqual(accumulator.segments.count, 3)
        let headers = window.captions.filter { window.speakerHeaderIDs.contains($0.id) }.map(\.segment.speaker)
        XCTAssertEqual(headers, ["Dave", "Ann"])
    }

    func testSegmentIndexLookupClampsToTranscript() {
        var accumulator = InlineSegmentAccumulator()
        accumulator.update(with: sources((0..<12).map { cue($0) }))
        let segments = accumulator.segments

        XCTAssertEqual(InlineCaptionWindow.segmentIndex(in: segments, at: -5), 0)
        XCTAssertEqual(InlineCaptionWindow.segmentIndex(in: segments, at: segments[1].startTime + 0.1), 1)
        XCTAssertEqual(InlineCaptionWindow.segmentIndex(in: segments, at: 10_000), segments.count - 1)
    }

    // MARK: Live value cues

    func testLiveSourcesMergeTentativeCuesWithoutSortingOrModels() {
        let finals = (0..<6).map { cue($0) }
        let tentative = [cue(7), cue(2, text: "tentative overlap")]

        let merged: [TranscriptSegmentSource] = LiveTranscriptController.mergedSources(final: finals, tentative: tentative)

        let reference = (finals + tentative).sorted { $0.start < $1.start }
        XCTAssertEqual(merged.map(\.id), reference.map(\.id))
        XCTAssertTrue(merged.allSatisfy { $0.sourceRawValue == CachedTranscriptSource.localAI.rawValue })
    }

    // MARK: Overlay state

    func testOverlayStateDerivation() {
        let url = URL(string: "https://example.com/episode.mp3")!
        var filled = InlineSegmentAccumulator()
        filled.update(with: sources((0..<4).map { cue($0) }))
        let empty = InlineSegmentAccumulator()

        XCTAssertEqual(InlineTranscriptState.make(kind: nil, episodeURL: url, revision: 1,
                                                  accumulator: empty, usesPublisherAlignment: false),
                       .status(.noTranscript))
        XCTAssertEqual(InlineTranscriptState.make(kind: .live, episodeURL: url, revision: 1,
                                                  accumulator: empty, usesPublisherAlignment: false),
                       .status(.liveStarting))
        XCTAssertEqual(InlineTranscriptState.make(kind: .savedPartial, episodeURL: url, revision: 1,
                                                  accumulator: empty, usesPublisherAlignment: false),
                       .status(.noTranscript))

        guard case .caption(let document) = InlineTranscriptState.make(
            kind: .document, episodeURL: url, revision: 2, accumulator: filled, usesPublisherAlignment: true
        ) else { return XCTFail("expected captions") }
        XCTAssertTrue(document.canFollowPlayback)
        XCTAssertTrue(document.usesPublisherAlignment)
        XCTAssertEqual(document.segments, filled.segments)

        guard case .caption(let live) = InlineTranscriptState.make(
            kind: .live, episodeURL: url, revision: 3, accumulator: filled, usesPublisherAlignment: true
        ) else { return XCTFail("expected captions") }
        XCTAssertTrue(live.canFollowPlayback)
        XCTAssertFalse(live.usesPublisherAlignment, "live captions are on the audio clock")

        guard case .caption(let partial) = InlineTranscriptState.make(
            kind: .savedPartial, episodeURL: url, revision: 4, accumulator: filled, usesPublisherAlignment: false
        ) else { return XCTFail("expected captions") }
        XCTAssertFalse(partial.canFollowPlayback)
    }

    @MainActor
    func testPresenterStartsInPreparingStateWithoutTranscriptWork() {
        let presenter = InlineTranscriptPresenter()
        XCTAssertEqual(presenter.state, .preparing)
    }

    // MARK: Reopen cache (#495)

    @MainActor
    func testReopenCacheIsBoundedAndInvalidatedByReferenceChanges() {
        let cache = InlineCaptionDocumentCache()
        var accumulator = InlineSegmentAccumulator()
        accumulator.update(with: sources((0..<8).map { cue($0) }))
        let urls = (0..<3).map { URL(string: "https://example.com/\($0).mp3")! }

        for url in urls { cache.store(accumulator, usesPublisherAlignment: true, for: url) }
        XCTAssertNil(cache.entry(for: urls[0]), "oldest entry is evicted")
        XCTAssertEqual(cache.entry(for: urls[2])?.accumulator.segments, accumulator.segments)
        XCTAssertEqual(cache.entry(for: urls[2])?.usesPublisherAlignment, true)

        NotificationCenter.default.post(
            name: .episodeReferencesDidChange,
            object: nil,
            userInfo: [EpisodeReferenceNotificationKey.episodeURL: urls[2]]
        )
        XCTAssertNil(cache.entry(for: urls[2]), "a changed transcript is not reused")
        XCTAssertNotNil(cache.entry(for: urls[1]))
    }

    // MARK: Automatic live transcription policy (#494)

    func testAutomaticLiveWorkYieldsToLowPowerAndHeat() {
        XCTAssertNil(LiveTranscriptController.automaticWorkBlocker(lowPower: false, thermal: .nominal))
        XCTAssertNil(LiveTranscriptController.automaticWorkBlocker(lowPower: false, thermal: .fair))
        XCTAssertEqual(LiveTranscriptController.automaticWorkBlocker(lowPower: true, thermal: .nominal), .lowPower)
        XCTAssertEqual(LiveTranscriptController.automaticWorkBlocker(lowPower: false, thermal: .serious), .thermal)
        XCTAssertEqual(LiveTranscriptController.automaticWorkBlocker(lowPower: false, thermal: .critical), .thermal)
    }

    func testLiveLookaheadScalesWithPlaybackRate() {
        XCTAssertEqual(LiveTranscriptController.lookahead(playbackRate: 1), 14)
        XCTAssertEqual(LiveTranscriptController.lookahead(playbackRate: 0.75), 14, "never plans less than at 1x")
        XCTAssertEqual(LiveTranscriptController.lookahead(playbackRate: 2.5), 35)
        XCTAssertEqual(LiveTranscriptController.lookahead(playbackRate: 10), 42, "bounded")
        XCTAssertEqual(LiveTranscriptController.lookahead(playbackRate: .nan), 14)
    }
}
