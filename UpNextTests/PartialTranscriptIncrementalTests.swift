import XCTest
@testable import UpNext

/// Full Transcript view: incremental preparation of live and saved-partial
/// transcripts (#493).
final class PartialTranscriptIncrementalTests: XCTestCase {

    // Groups of four cues separated by a pause longer than the full maximum
    // silence, so every group becomes its own full-transcript segment.
    private func cue(_ index: Int, text: String? = nil, id: UUID = UUID(), words: Bool = false) -> LiveTranscriptState.Cue {
        let start = Double(index) * 2 + Double(index / 4) * 4
        let body = text ?? "Cue \(index) is short."
        let spans = words
            ? [TranscriptTimedSpan(location: 0, length: 3, startTime: start, endTime: start + 0.4, cueLevel: false)]
            : []
        return LiveTranscriptState.Cue(id: id, text: body, start: start, end: start + 1.5, spans: spans)
    }

    private func sources(_ final: [LiveTranscriptState.Cue], tentative: [LiveTranscriptState.Cue] = []) -> [TranscriptSegmentSource] {
        LiveTranscriptController.mergedSources(final: final, tentative: tentative)
    }

    private func assertEquivalentToFullRebuild(
        _ snapshot: TranscriptPreparedSnapshot,
        _ sources: [TranscriptSegmentSource],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let full = TranscriptPreparedSnapshot.make(from: sources, sourcesAreSorted: true)
        XCTAssertEqual(snapshot.segments, full.segments, file: file, line: line)
        XCTAssertEqual(snapshot.presentation.segments, full.presentation.segments, file: file, line: line)
        XCTAssertEqual(snapshot.sourceMetadata, full.sourceMetadata, file: file, line: line)
        XCTAssertEqual(snapshot.presentation.timingQuality, full.presentation.timingQuality, file: file, line: line)
        XCTAssertTrue(snapshot.hasSameDocumentLayout(as: full), file: file, line: line)
    }

    func testAppendingCuesKeepsEarlierSegmentsAndEqualsFullRebuild() {
        var accumulator = PartialTranscriptSnapshotAccumulator()
        var cues: [LiveTranscriptState.Cue] = []
        var previous: TranscriptPreparedSnapshot?

        for index in 0..<120 {
            cues.append(cue(index, words: index.isMultiple(of: 3)))
            let snapshot = accumulator.update(with: sources(cues))
            let update = try! XCTUnwrap(accumulator.lastUpdate)

            XCTAssertTrue(update.changed)
            XCTAssertLessThanOrEqual(update.rebuiltSegments, 2)
            if let previous {
                // Every closed segment keeps its ID and value.
                XCTAssertGreaterThanOrEqual(update.reusedSegments, previous.segments.count - 1)
                XCTAssertEqual(Array(snapshot.segments.prefix(update.reusedSegments)),
                               Array(previous.segments.prefix(update.reusedSegments)))
                XCTAssertTrue(snapshot.continuesDocumentLayout(of: previous))
            }
            assertEquivalentToFullRebuild(snapshot, sources(cues))
            previous = snapshot
        }
        XCTAssertEqual(previous?.segments.count, 30)
    }

    func testSameCountRevisionOfLastCueIsRegrouped() {
        var accumulator = PartialTranscriptSnapshotAccumulator()
        let final = (0..<10).map { cue($0) }
        let tentativeID = UUID()
        let first = accumulator.update(with: sources(final, tentative: [cue(10, text: "Hel", id: tentativeID)]))

        let revisedSources = sources(final, tentative: [cue(10, text: "Hello there, revised.", id: tentativeID)])
        let revised = accumulator.update(with: revisedSources)
        let update = try! XCTUnwrap(accumulator.lastUpdate)

        XCTAssertEqual(first.segments.count, revised.segments.count)
        XCTAssertTrue(update.changed)
        XCTAssertEqual(update.reusedSegments, revised.segments.count - 1)
        XCTAssertTrue(revised.segments.last!.text.hasSuffix("Hello there, revised."))
        XCTAssertNotEqual(first, revised)
        XCTAssertTrue(revised.continuesDocumentLayout(of: first))
        assertEquivalentToFullRebuild(revised, revisedSources)

        // Repeating the same sources is a no-op that returns the same snapshot.
        XCTAssertEqual(accumulator.update(with: revisedSources), revised)
        XCTAssertEqual(accumulator.lastUpdate?.changed, false)
    }

    func testRemovedTentativeCueAndUnsupportedInputMatchFullRebuild() {
        var accumulator = PartialTranscriptSnapshotAccumulator()
        let final = (0..<9).map { cue($0) }
        accumulator.update(with: sources(final, tentative: [cue(9)]))
        assertEquivalentToFullRebuild(accumulator.update(with: sources(final)), sources(final))

        // Mixed document sources fall back to the full rebuild.
        let legacy = TranscriptSegmentSource(text: "Legacy line.", startTime: 100)
        let mixed = sources(final) + [legacy]
        XCTAssertFalse(PartialTranscriptSnapshotAccumulator.supportsIncrementalUpdate(mixed))
        XCTAssertEqual(accumulator.update(with: mixed), TranscriptPreparedSnapshot.make(from: mixed, sourcesAreSorted: true))
        XCTAssertNil(accumulator.lastUpdate)

        XCTAssertEqual(accumulator.update(with: []).segments, [])
    }

    func testStaleGenerationIsDropped() {
        var generation = TranscriptPreparationGeneration()
        let first = generation.begin()
        XCTAssertTrue(generation.isCurrent(first))
        let second = generation.begin()
        XCTAssertFalse(generation.isCurrent(first))
        XCTAssertTrue(generation.isCurrent(second))
    }

    func testReplacedDocumentDoesNotContinueLayout() {
        let a = TranscriptPreparedSnapshot.make(from: sources((0..<4).map { cue($0) }), sourcesAreSorted: true)
        let b = TranscriptPreparedSnapshot.make(from: sources((0..<4).map { cue($0) }), sourcesAreSorted: true)
        XCTAssertFalse(b.continuesDocumentLayout(of: a))
        XCTAssertTrue(a.continuesDocumentLayout(of: a))
    }
}
