import SwiftData
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

    // MARK: Publisher timing enrichment policy (#490)

    func testEnrichmentLookaheadScalesWithRateAndIsBounded() {
        XCTAssertEqual(OptionalSpeechWorkPolicy.enrichmentLookahead(playbackRate: 1), 30)
        XCTAssertEqual(OptionalSpeechWorkPolicy.enrichmentLookahead(playbackRate: 0.5), 30)
        XCTAssertEqual(OptionalSpeechWorkPolicy.enrichmentLookahead(playbackRate: 2.5), 75)
        XCTAssertEqual(OptionalSpeechWorkPolicy.enrichmentLookahead(playbackRate: 5), 90)
    }

    func testEnrichmentWindowsStartAtPlayheadAndStayContiguous() {
        let centers = OptionalSpeechWorkPolicy.enrichmentWindowCenters(
            audioTime: 100, mediaDuration: 3600, playbackRate: 1
        )
        // 100 s lies in the window starting at 98 s.
        XCTAssertEqual(centers.first, 101.5)
        let ahead = centers.filter { $0 >= 101.5 }
        XCTAssertEqual(ahead, ahead.sorted())
        XCTAssertTrue(zip(ahead, ahead.dropFirst()).allSatisfy { $1 - $0 == 7 }, "no holes ahead")
        XCTAssertGreaterThanOrEqual(ahead.last! + 3.5, 130, "covers the 30 s lookahead")
        XCTAssertEqual(centers.last, 94.5, "the short behind window comes last")

        let fast = OptionalSpeechWorkPolicy.enrichmentWindowCenters(audioTime: 100, mediaDuration: 3600, playbackRate: 2.5)
        XCTAssertGreaterThan(fast.count, centers.count)
    }

    func testEnrichmentWindowsStayInsideTheMedia() {
        let start = OptionalSpeechWorkPolicy.enrichmentWindowCenters(audioTime: 0, mediaDuration: 60, playbackRate: 1)
        XCTAssertEqual(start.first, 3.5)
        XCTAssertTrue(start.allSatisfy { $0 >= 3.5 && $0 <= 56.5 })

        let end = OptionalSpeechWorkPolicy.enrichmentWindowCenters(audioTime: 58, mediaDuration: 60, playbackRate: 1)
        XCTAssertEqual(Set(end).count, end.count, "clamped windows are deduplicated")
        XCTAssertTrue(end.allSatisfy { $0 <= 56.5 })
        XCTAssertTrue(OptionalSpeechWorkPolicy.enrichmentWindowCenters(audioTime: .nan, mediaDuration: 60, playbackRate: 1).isEmpty)
    }

    func testOptionalSpeechWorkYieldsToPressure() {
        XCTAssertNil(OptionalSpeechWorkPolicy.blocker(lowPower: false, thermal: .fair))
        XCTAssertEqual(OptionalSpeechWorkPolicy.blocker(lowPower: true, thermal: .nominal), .lowPower)
        XCTAssertEqual(OptionalSpeechWorkPolicy.blocker(lowPower: false, thermal: .serious), .thermal)
    }

    // MARK: #493 overlay transitions, reopen cache and Speech policy

    private func libraryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Podcast.self, PodcastMetaData.self, Episode.self, EpisodeMetaData.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    @MainActor
    func testPresenterWithoutEpisodeShowsMissingStatusImmediately() throws {
        let presenter = InlineTranscriptPresenter()
        var requested = false
        presenter.show(episodeURL: nil, container: try libraryContainer()) { requested = true }
        XCTAssertEqual(presenter.state, .status(.noTranscript))
        XCTAssertFalse(requested, "no episode never requests live transcription")
        presenter.stop()
    }

    /// #495 before #494: a reopened overlay paints cached captions in the
    /// caller's frame, before any load or live auto-start can run.
    @MainActor
    func testReopenedOverlayPaintsCachedCaptionsInTheSameFrame() throws {
        let url = URL(string: "https://example.com/\(UUID().uuidString).mp3")!
        var accumulator = InlineSegmentAccumulator()
        accumulator.update(with: sources((0..<8).map { cue($0) }))
        InlineCaptionDocumentCache.shared.store(accumulator, usesPublisherAlignment: true, for: url)
        defer { InlineCaptionDocumentCache.shared.invalidate(episodeURL: url) }

        let presenter = InlineTranscriptPresenter()
        var requested = false
        presenter.show(episodeURL: url, container: try libraryContainer()) { requested = true }
        guard case .caption(let snapshot) = presenter.state else {
            presenter.stop()
            return XCTFail("expected cached captions on the first frame")
        }
        XCTAssertEqual(snapshot.kind, .document)
        XCTAssertEqual(snapshot.segments, accumulator.segments)
        XCTAssertTrue(snapshot.usesPublisherAlignment)
        XCTAssertFalse(requested)
        presenter.stop()

        let uncached = InlineTranscriptPresenter()
        uncached.show(episodeURL: URL(string: "https://example.com/\(UUID().uuidString).mp3")!,
                      container: try libraryContainer())
        XCTAssertEqual(uncached.state, .preparing, "a cold open shows status before heavy work")
        uncached.stop()
    }

    @MainActor
    func testReopenCacheRefreshesRecencyAndGlobalChangeClearsAll() {
        let cache = InlineCaptionDocumentCache()
        var accumulator = InlineSegmentAccumulator()
        accumulator.update(with: sources((0..<4).map { cue($0) }))
        let urls = (0..<3).map { URL(string: "https://example.com/recency-\($0).mp3")! }

        cache.store(accumulator, usesPublisherAlignment: false, for: urls[0])
        cache.store(accumulator, usesPublisherAlignment: false, for: urls[1])
        cache.store(accumulator, usesPublisherAlignment: false, for: urls[0]) // Reopened.
        cache.store(accumulator, usesPublisherAlignment: false, for: urls[2])
        XCTAssertNotNil(cache.entry(for: urls[0]), "the recently reopened overlay survives")
        XCTAssertNil(cache.entry(for: urls[1]))

        NotificationCenter.default.post(name: .episodeReferencesDidChange, object: nil, userInfo: nil)
        XCTAssertNil(cache.entry(for: urls[0]))
        XCTAssertNil(cache.entry(for: urls[2]))
    }

    func testSeekSettleDelayCoalescesSkipBursts() {
        // Repeated 30 s skips restart Speech once, after the playhead settles.
        XCTAssertGreaterThanOrEqual(OptionalSpeechWorkPolicy.seekSettleDelay, .milliseconds(400))
        XCTAssertLessThanOrEqual(OptionalSpeechWorkPolicy.seekSettleDelay, .milliseconds(600))
    }

    func testOptionalSpeechWorkCoversListeningTimeAtEverySupportedRate() {
        for (rate, lookahead) in [(Float(1), 30.0), (1.5, 45), (2, 60), (2.5, 75)] {
            XCTAssertEqual(OptionalSpeechWorkPolicy.enrichmentLookahead(playbackRate: rate), lookahead)
            let centers = OptionalSpeechWorkPolicy.enrichmentWindowCenters(
                audioTime: 600, mediaDuration: 7_200, playbackRate: rate)
            let window = OptionalSpeechWorkPolicy.enrichmentWindow
            XCTAssertGreaterThanOrEqual(centers.max()! + window / 2, 600 + lookahead, "rate \(rate)")
            XCTAssertLessThanOrEqual(centers.min()! - window / 2, 600 - OptionalSpeechWorkPolicy.enrichmentBehind)
            XCTAssertLessThanOrEqual(centers.count, 16, "bounded per pass")
        }
        // A ±30 min seek plans an entirely new set of windows.
        let here = Set(OptionalSpeechWorkPolicy.enrichmentWindowCenters(audioTime: 1_800, mediaDuration: 7_200, playbackRate: 1))
        for target in [0.0, 3_600] {
            let there = Set(OptionalSpeechWorkPolicy.enrichmentWindowCenters(audioTime: target, mediaDuration: 7_200, playbackRate: 1))
            XCTAssertTrue(here.isDisjoint(with: there))
        }
        for (rate, lookahead) in [(Float(1), 14.0), (1.5, 21), (2, 28), (2.5, 35)] {
            XCTAssertEqual(LiveTranscriptController.lookahead(playbackRate: rate), lookahead)
        }
    }

    @MainActor
    func testAutomaticLiveStartSkipsAnEpisodeThatIsNotPlaying() async throws {
        let container = try libraryContainer()
        let episode = Episode(guid: "auto-start", title: "Not playing",
                              url: URL(string: "https://example.com/\(UUID().uuidString).mp3")!, duration: 60)
        container.mainContext.insert(episode)
        let skip = await LiveTranscriptController.shared.startAutomaticallyIfAppropriate(
            episode: episode, container: container)
        XCTAssertEqual(skip, .notCurrentEpisode)
        XCTAssertFalse(LiveTranscriptController.shared.isActive(for: episode))
    }
}
