import XCTest
@testable import UpNext

final class PublisherTimingEvidenceTests: XCTestCase {
    private func line(_ text: String, start: Double, end: Double, speaker: String = "Host") -> TranscriptSegmentSource {
        TranscriptSegmentSource(speaker: speaker, text: text, startTime: start, endTime: end,
                                sourceRawValue: CachedTranscriptSource.publisher.rawValue)
    }

    /// The pre-refactor rebasing in `TranscriptPresentationSnapshot.resolve`, kept as the reference.
    private func legacyFullRebase(document: TranscriptDocumentSnapshot,
                                  wordsByLine: [UUID: [TranscriptTimedSpan]]) -> [UUID: [TranscriptTimedSpan]] {
        var result: [UUID: [TranscriptTimedSpan]] = [:]
        var offset = 0
        for paragraph in document.segments {
            let range = offset..<(offset + paragraph.lineIDs.count)
            offset = range.upperBound
            guard paragraph.lineIDs.contains(where: { wordsByLine[$0] != nil }) else { continue }
            let mapped = document.lines[range].map { line in
                let text = line.text as NSString
                return TranscriptSegmentSource(id: line.id, speaker: line.speaker, text: line.text,
                    startTime: line.startTime, endTime: line.endTime,
                    timedSpans: (wordsByLine[line.id] ?? []).filter {
                        let r = NSRange(location: $0.location, length: $0.length)
                        return $0.cueLevel != true && $0.startTime >= 0 && $0.location >= 0 && $0.length > 0
                            && $0.length <= text.length - min($0.location, text.length)
                            && text.rangeOfComposedCharacterSequences(for: r) == r
                    })
            }
            for segment in TranscriptSegmentBuilder.makeSegments(fromSorted: mapped, options: .full) {
                let words = segment.timedSpans.filter { $0.cueLevel != true }
                if !words.isEmpty { result[segment.id] = words }
            }
        }
        return result
    }

    private func sampleDocument() throws -> TranscriptDocumentSnapshot {
        // Long enough that .compact splits where .full does not; a speaker change forces a third paragraph.
        let lines = [
            line("  The first sentence of this episode is reasonably long, so that grouping matters here.", start: 0, end: 5),
            line("A second sentence follows it and pushes the compact card over its soft limit now.", start: 5, end: 10),
            line("Then a third 👋 sentence closes the opening paragraph.", start: 10, end: 14),
            line("Guest speaks here.", start: 14, end: 16, speaker: "Guest")
        ]
        return try XCTUnwrap(TranscriptDocumentSnapshot.resolve(episodeID: "ep", storedLines: lines))
    }

    private func sampleWords(_ document: TranscriptDocumentSnapshot) -> [UUID: [TranscriptTimedSpan]] {
        let lines = document.lines
        return [
            lines[0].id: [.init(location: 2, length: 3, startTime: 30, endTime: 30.2),
                          .init(location: 6, length: 5, startTime: 30.2, endTime: 30.5),
                          .init(location: 0, length: 4, startTime: 30, endTime: 35, cueLevel: true),
                          .init(location: 12, length: 8, startTime: -1, endTime: 31)],
            lines[1].id: [.init(location: 2, length: 6, startTime: 36, endTime: 36.4)],
            lines[2].id: [.init(location: 13, length: 1, startTime: 41, endTime: 41.2), // Splits the emoji.
                          .init(location: 13, length: 2, startTime: 41, endTime: 41.2)],
            lines[3].id: [.init(location: 0, length: 5, startTime: 45, endTime: 45.3)]
        ]
    }

    func testFullRebaseMatchesPreviousResolveOutput() throws {
        let document = try sampleDocument()
        let words = sampleWords(document)
        let rebased = TranscriptSegmentBuilder.rebasedWords(lines: document.lines, wordsByLine: words, options: .full)
        XCTAssertEqual(rebased, legacyFullRebase(document: document, wordsByLine: words))
        XCTAssertEqual(Set(rebased.keys), Set(document.segments.map(\.id)))
        let evidence = PublisherTranscriptTimingEvidence(episodeID: "ep", mediaFingerprint: "media",
            transcriptRevision: try XCTUnwrap(document.timingRevision), timeline: nil, wordsByLine: words)
        let resolved = TranscriptPresentationSnapshot.resolve(document: document, mediaFingerprint: "media", evidence: evidence)
        XCTAssertEqual(resolved.enhancedWordsBySegment, rebased)
        XCTAssertEqual(resolved.timingQuality, .enhancedWords)
        // Untouched paragraphs are not reported.
        let partial = TranscriptSegmentBuilder.rebasedWords(lines: document.lines,
            wordsByLine: [document.lines[3].id: words[document.lines[3].id]!], options: .full)
        XCTAssertEqual(Array(partial.keys), [document.lines[3].id])
        XCTAssertTrue(TranscriptSegmentBuilder.rebasedWords(lines: document.lines, wordsByLine: [:], options: .full).isEmpty)
    }

    func testCompactRebaseKeysCompactSegmentsWithDisplayOffsets() throws {
        let document = try sampleDocument()
        let compact = TranscriptSegmentBuilder.makeSegments(fromSorted: document.lines, options: .compact)
        XCTAssertGreaterThan(compact.count, document.segments.count, "fixture must split differently in .compact")
        let rebased = TranscriptSegmentBuilder.rebasedWords(lines: document.lines,
                                                            wordsByLine: sampleWords(document), options: .compact)
        XCTAssertTrue(Set(rebased.keys).isSubset(of: Set(compact.map(\.id))))
        for segment in compact {
            for span in rebased[segment.id] ?? [] {
                XCTAssertNotEqual(span.cueLevel, true)
                XCTAssertGreaterThanOrEqual(span.startTime, 0)
                XCTAssertNotNil(Range(NSRange(location: span.location, length: span.length), in: segment.text))
            }
        }
        // First line's leading whitespace is trimmed: "The" at 2 in the line is 0 in the segment.
        let first = try XCTUnwrap(rebased[document.lines[0].id])
        // The compact segment may also hold the next line; check this line's words.
        XCTAssertEqual(Array(first.prefix(2)), [.init(location: 0, length: 3, startTime: 30, endTime: 30.2),
                               .init(location: 4, length: 5, startTime: 30.2, endTime: 30.5)])
        let emojiSegment = try XCTUnwrap(compact.first { $0.lineIDs.contains(document.lines[2].id) })
        let emojiWords = try XCTUnwrap(rebased[emojiSegment.id])
        let emoji = try XCTUnwrap(emojiWords.last)
        XCTAssertEqual((emojiSegment.text as NSString).substring(with: NSRange(location: emoji.location, length: emoji.length)), "👋")
        XCTAssertEqual(emojiWords.filter { $0.startTime == 41 }.count, 1)
        let guest = try XCTUnwrap(rebased[document.lines[3].id])
        XCTAssertEqual(guest, [.init(location: 0, length: 5, startTime: 45, endTime: 45.3)])
    }

    func testResolveRejectsStaleEvidence() throws {
        let document = try sampleDocument()
        let revision = try XCTUnwrap(document.timingRevision)
        let words = sampleWords(document)
        for (episode, fingerprint, rev) in [("other", "media", revision), ("ep", "old", revision), ("ep", "media", "stale")] {
            let evidence = PublisherTranscriptTimingEvidence(episodeID: episode, mediaFingerprint: fingerprint,
                transcriptRevision: rev, timeline: nil, wordsByLine: words)
            let resolved = TranscriptPresentationSnapshot.resolve(document: document, mediaFingerprint: "media", evidence: evidence)
            XCTAssertTrue(resolved.enhancedWordsBySegment.isEmpty)
            XCTAssertNotEqual(resolved.timingQuality, .enhancedWords)
        }
    }

    func testMappingConversionKeepsDocumentLinesOnly() {
        let known = UUID(), unknown = UUID()
        let mappings: [PublisherTranscriptTimingOverlay.Mapping] = [
            .init(tokenIndex: 1, lineID: known, location: 6, length: 3, audioStart: 2, audioEnd: 2.5, confidence: 0.9),
            .init(tokenIndex: 0, lineID: known, location: 0, length: 5, audioStart: 1, audioEnd: 1.5, confidence: 0.9),
            .init(tokenIndex: 2, lineID: unknown, location: 0, length: 2, audioStart: 3, audioEnd: 3.2, confidence: 0.9)
        ]
        XCTAssertEqual(PublisherTimingEvidenceLoader.wordsByLine(from: mappings, lineIDs: [known]), [known: [
            .init(location: 0, length: 5, startTime: 1, endTime: 1.5),
            .init(location: 6, length: 3, startTime: 2, endTime: 2.5)
        ]])
    }

    func testLoaderReadsCacheOnlyForPublisherDocumentWithMedia() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appendingPathComponent("episode.mp3")
        try Data((0..<4096).map { UInt8($0 % 251) }).write(to: media)
        let cache = PublisherTranscriptTimingOverlayCache(cacheDirectory: directory)
        let service = TranscriptSynchronizationService()
        let document = try sampleDocument()
        let revision = try XCTUnwrap(document.timingRevision)
        let fingerprint = try await service.boundedFingerprint(for: media)
        let key = PublisherTranscriptTimingOverlay.Key(episodeID: "ep", mediaFingerprint: fingerprint, transcriptRevision: revision)
        let changed = try await cache.merge([
            .init(tokenIndex: 0, lineID: document.lines[3].id, location: 0, length: 5,
                  audioStart: 45, audioEnd: 45.3, confidence: 0.95)
        ], for: key)
        XCTAssertTrue(changed)
        let episodeURL = URL(string: "https://example.com/episode.mp3")!

        let evidence = await PublisherTimingEvidenceLoader.load(document: document, episodeURL: episodeURL,
            localMediaURL: media, audioWindow: 40..<50, service: service, cache: cache)
        XCTAssertEqual(evidence?.mediaFingerprint, fingerprint)
        XCTAssertEqual(evidence?.transcriptRevision, revision)
        XCTAssertEqual(evidence?.wordsByLine[document.lines[3].id]?.count, 1)

        let outside = await PublisherTimingEvidenceLoader.load(document: document, episodeURL: episodeURL,
            localMediaURL: media, audioWindow: 0..<10, service: service, cache: cache)
        XCTAssertNil(outside)
        let missing = await PublisherTimingEvidenceLoader.load(document: document, episodeURL: episodeURL,
            localMediaURL: directory.appendingPathComponent("missing.mp3"), audioWindow: 40..<50,
            service: service, cache: cache)
        XCTAssertNil(missing)
        let generated = try XCTUnwrap(TranscriptDocumentSnapshot.resolve(episodeID: "ep", storedLines: document.lines.map {
            TranscriptSegmentSource(id: $0.id, speaker: $0.speaker, text: $0.text, startTime: $0.startTime,
                                    endTime: $0.endTime, sourceRawValue: CachedTranscriptSource.localAI.rawValue)
        }))
        let notPublisher = await PublisherTimingEvidenceLoader.load(document: generated, episodeURL: episodeURL,
            localMediaURL: media, audioWindow: 40..<50, service: service, cache: cache)
        XCTAssertNil(notPublisher)
    }
}
