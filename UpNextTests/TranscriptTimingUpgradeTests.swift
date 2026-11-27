import XCTest
@testable import UpNext

/// Verified publisher word timing upgrades highlighting in place (#492): rows,
/// caption snapshots and their revisions never change for a timing-only update.
@MainActor
final class TranscriptTimingUpgradeTests: XCTestCase {

    private func publisherLines(count: Int = 12) -> [TranscriptSegmentSource] {
        (0..<count).map { index in
            TranscriptSegmentSource(
                speaker: index < count / 2 ? "Ada" : "Grace",
                text: "Line \(index) says hello world.",
                startTime: Double(index) * 4,
                endTime: Double(index) * 4 + 3,
                sourceRawValue: CachedTranscriptSource.publisher.rawValue
            )
        }
    }

    private func document(_ lines: [TranscriptSegmentSource], episodeID: String = "episode") -> TranscriptDocumentSnapshot {
        guard let document = TranscriptDocumentSnapshot.resolve(episodeID: episodeID, storedLines: lines) else {
            XCTFail("Expected a publisher document")
            fatalError()
        }
        return document
    }

    /// Audio-clock spans for "hello" in every line, offset from the transcript clock.
    private func wordsByLine(_ lines: [TranscriptSegmentSource]) -> [UUID: [TranscriptTimedSpan]] {
        Dictionary(uniqueKeysWithValues: lines.map { line in
            let location = (line.text as NSString).range(of: "hello").location
            return (line.id, [TranscriptTimedSpan(location: location, length: 5,
                                                  startTime: line.startTime + 7.5, endTime: line.startTime + 8)])
        })
    }

    private func source(_ document: TranscriptDocumentSnapshot, episodeURL: URL,
                        options: TranscriptSegmentBuilder.Options = .full) -> PublisherTimingUpgradeLoader.Source {
        PublisherTimingUpgradeLoader.Source(
            episodeURL: episodeURL, episodeID: document.episodeID,
            localMediaURL: URL(fileURLWithPath: "/tmp/episode.mp3"), document: document, options: options)
    }

    private func neverLoads() -> PublisherTimingUpgradeLoader {
        PublisherTimingUpgradeLoader { _, _ in nil }
    }

    // MARK: Layout is unchanged

    func testTimingOnlyUpdateKeepsFullTranscriptLayout() {
        let lines = publisherLines()
        let document = document(lines)
        let base = TranscriptPresentationSnapshot.resolve(document: document)
        let evidence = PublisherTranscriptTimingEvidence(
            episodeID: document.episodeID, mediaFingerprint: "media", transcriptRevision: document.timingRevision!,
            timeline: nil, wordsByLine: wordsByLine(lines))
        let upgraded = TranscriptPresentationSnapshot.resolve(document: document, mediaFingerprint: "media",
                                                              evidence: evidence)
        let metadata = TranscriptSourceMetadata.make(from: lines)
        let before = TranscriptPreparedSnapshot(segments: base.segments, sourceMetadata: metadata, presentation: base)
        let after = TranscriptPreparedSnapshot(segments: upgraded.segments, sourceMetadata: metadata, presentation: upgraded)

        XCTAssertEqual(upgraded.timingQuality, .enhancedWords)
        XCTAssertTrue(after.hasSameDocumentLayout(as: before))
        XCTAssertTrue(after.continuesDocumentLayout(of: before))

        let rebased = TranscriptSegmentBuilder.rebasedWords(
            lines: document.lines, wordsByLine: evidence.wordsByLine, options: .full)
        XCTAssertFalse(rebased.isEmpty)
        XCTAssertTrue(Set(rebased.keys).isSubset(of: Set(before.segments.map(\.id))))
    }

    func testTimingOnlyUpdateLeavesInlineCaptionSnapshotUnchanged() {
        let lines = publisherLines()
        let document = document(lines)
        var accumulator = InlineSegmentAccumulator()
        accumulator.update(with: document.lines)
        let episodeURL = URL(string: "https://example.com/episode.mp3")!
        let state = InlineTranscriptState.make(kind: .document, episodeURL: episodeURL, revision: 3,
                                               accumulator: accumulator, usesPublisherAlignment: true)
        guard case .caption(let snapshot) = state else { return XCTFail("Expected captions") }
        let segments = snapshot.segments

        let rebased = TranscriptSegmentBuilder.rebasedWords(
            lines: document.lines, wordsByLine: wordsByLine(lines), options: accumulator.options)
        let timing = TranscriptEnhancedWords(revision: 1, words: rebased)

        // The overlay's compact segments receive the words by their own IDs …
        XCTAssertFalse(rebased.isEmpty)
        XCTAssertTrue(Set(rebased.keys).isSubset(of: Set(segments.map(\.id))))
        XCTAssertNotEqual(timing, .empty)
        // … while the caption snapshot (segments and revision) is untouched.
        XCTAssertEqual(snapshot.revision, 3)
        XCTAssertEqual(snapshot.segments, segments)
        let again = InlineTranscriptState.make(kind: .document, episodeURL: episodeURL, revision: 3,
                                               accumulator: accumulator, usesPublisherAlignment: true)
        XCTAssertEqual(again, state)
    }

    // MARK: Window

    func testWindowCoversLookBehindAndLookAhead() {
        XCTAssertEqual(PublisherTimingUpgradeLoader.window(around: 100), 70..<250)
        XCTAssertEqual(PublisherTimingUpgradeLoader.window(around: 10), 0..<160)
        XCTAssertEqual(PublisherTimingUpgradeLoader.window(around: .nan), 0..<150)
    }

    func testNeedsReloadWhenPlayheadLeavesLoadedWindow() {
        let window = PublisherTimingUpgradeLoader.window(around: 100)
        XCTAssertTrue(PublisherTimingUpgradeLoader.needsReload(loadedWindow: nil, playhead: 100))
        XCTAssertFalse(PublisherTimingUpgradeLoader.needsReload(loadedWindow: window, playhead: 100))
        XCTAssertFalse(PublisherTimingUpgradeLoader.needsReload(loadedWindow: window, playhead: 200))
        // Close to the end of the window, after a seek forward or back.
        XCTAssertTrue(PublisherTimingUpgradeLoader.needsReload(loadedWindow: window, playhead: 230))
        XCTAssertTrue(PublisherTimingUpgradeLoader.needsReload(loadedWindow: window, playhead: 600))
        XCTAssertTrue(PublisherTimingUpgradeLoader.needsReload(loadedWindow: window, playhead: 20))
        XCTAssertFalse(PublisherTimingUpgradeLoader.needsReload(loadedWindow: window, playhead: .nan))
    }

    // MARK: Coalescing

    func testStaleEpisodeResultIsDropped() {
        let lines = publisherLines()
        let first = URL(string: "https://example.com/a.mp3")!
        let second = URL(string: "https://example.com/b.mp3")!
        let loader = neverLoads()

        loader.configure(source(document(lines, episodeID: "a"), episodeURL: first), playhead: 0)
        let staleToken = try! XCTUnwrap(loader.currentToken)
        loader.configure(source(document(publisherLines(), episodeID: "b"), episodeURL: second), playhead: 0)
        let currentToken = try! XCTUnwrap(loader.currentToken)

        XCTAssertFalse(loader.isCurrent(staleToken))
        loader.receive(wordsByLine(lines), for: staleToken)
        XCTAssertEqual(loader.words, .empty)
        XCTAssertTrue(loader.words.words.isEmpty)

        let words = [UUID(): [TranscriptTimedSpan(location: 0, length: 4, startTime: 1, endTime: 2)]]
        loader.receive(words, for: currentToken)
        XCTAssertEqual(loader.words.words, words)
    }

    func testSameSourceIsANoOpAndStopClearsWords() {
        let episodeURL = URL(string: "https://example.com/a.mp3")!
        let source = source(document(publisherLines()), episodeURL: episodeURL)
        let loader = neverLoads()
        loader.configure(source, playhead: 0)
        let token = try! XCTUnwrap(loader.currentToken)
        let words = [UUID(): [TranscriptTimedSpan(location: 0, length: 4, startTime: 1, endTime: 2)]]
        loader.receive(words, for: token)
        let published = loader.words

        loader.configure(source, playhead: 30)
        XCTAssertTrue(loader.isCurrent(token))
        XCTAssertEqual(loader.words, published)

        loader.configure(nil, playhead: 0)
        XCTAssertNil(loader.currentToken)
        XCTAssertTrue(loader.words.words.isEmpty)
        XCTAssertNotEqual(loader.words, published)
    }

    func testNonPublisherOrMissingMediaHasNoSource() {
        let generated = publisherLines().map {
            TranscriptSegmentSource(id: $0.id, speaker: $0.speaker, text: $0.text, startTime: $0.startTime,
                                    endTime: $0.endTime, sourceRawValue: CachedTranscriptSource.localAI.rawValue)
        }
        let episodeURL = URL(string: "https://example.com/a.mp3")!
        let missingFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        XCTAssertNil(PublisherTimingUpgradeLoader.Source.make(
            episodeURL: episodeURL, episodeID: "a", localMediaURL: missingFile,
            document: document(publisherLines()), options: .full))
        XCTAssertNil(PublisherTimingUpgradeLoader.Source.make(
            episodeURL: episodeURL, episodeID: "a", localMediaURL: missingFile,
            document: TranscriptDocumentSnapshot.resolve(episodeID: "a", storedLines: generated), options: .full))
    }
}
