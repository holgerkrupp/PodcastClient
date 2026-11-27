import XCTest
@testable import UpNext

final class TranscriptSynchronizationTests: XCTestCase {
    func testOlderGapEncodingStillDecodes() throws {
        let data = Data(#"{"audioStart":10,"audioEnd":20,"transcriptTime":10}"#.utf8)
        let gap = try JSONDecoder().decode(TranscriptAudioGap.self, from: data)
        XCTAssertNil(gap.transcriptEnd)
        XCTAssertEqual(gap.audioEnd, 20)
    }
    func testTranscriptRevisionChangesWhenInlineTimingChanges() throws {
        let first = TranscriptAlignmentCandidate(id: "one", transcriptTime: 1, text: "hello", source: .publisher,
            endTime: 3, timedSpans: [TranscriptTimedSpan(location: 0, length: 5, startTime: 1, endTime: 2)])
        let changed = TranscriptAlignmentCandidate(id: "one", transcriptTime: 1, text: "hello", source: .publisher,
            endTime: 3, timedSpans: [TranscriptTimedSpan(location: 0, length: 5, startTime: 1.5, endTime: 2)])
        let original = try XCTUnwrap(TranscriptSynchronizationRevision.make(candidates: [first]))
        XCTAssertEqual(original, TranscriptSynchronizationRevision.make(candidates: [first]))
        XCTAssertNotEqual(original, TranscriptSynchronizationRevision.make(candidates: [changed]))
    }
    func testIdentityTimelinePreservesZeroOffset() throws {
        let timeline = try XCTUnwrap(TranscriptSynchronizationTimeline(anchors: [
            .init(transcriptTime: 0, audioTime: 0, confidence: 1),
            .init(transcriptTime: 120, audioTime: 120, confidence: 0.95)
        ]))
        XCTAssertEqual(timeline.audioTime(forTranscriptTime: 42) ?? -1, 42, accuracy: 0.001)
        XCTAssertEqual(timeline.transcriptTime(forAudioTime: 42) ?? -1, 42, accuracy: 0.001)
        XCTAssertNil(timeline.audioTime(forTranscriptTime: 121))
        XCTAssertNil(timeline.transcriptTime(forAudioTime: 121))
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

    func testRemovedAudioProducesNegativeOffset() throws {
        let timeline = try XCTUnwrap(TranscriptSynchronizationTimeline(anchors: [
            .init(transcriptTime: 120, audioTime: 45, confidence: 0.95),
            .init(transcriptTime: 180, audioTime: 105, confidence: 0.94)
        ]))
        XCTAssertEqual(timeline.audioTime(forTranscriptTime: 150) ?? -1, 75, accuracy: 0.001)
        XCTAssertEqual(timeline.transcriptTime(forAudioTime: 75) ?? -1, 150, accuracy: 0.001)
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
        XCTAssertEqual(timeline.transcriptTime(forAudioTime: 165) ?? -1, 90, accuracy: 0.001)
        XCTAssertEqual(timeline.audioTime(forTranscriptTime: 60) ?? -1, 135, accuracy: 0.001)
        XCTAssertEqual(timeline.audioTime(forTranscriptTime: 90) ?? -1, 165, accuracy: 0.001)
    }

    func testMultipleGapsDoNotStretchSpeechOrSeekIntoInsertions() throws {
        let timeline = try XCTUnwrap(TranscriptSynchronizationTimeline(
            anchors: [
                .init(transcriptTime: 0, audioTime: 0, confidence: 1),
                .init(transcriptTime: 60, audioTime: 70, confidence: 1),
                .init(transcriptTime: 120, audioTime: 250, confidence: 1),
                .init(transcriptTime: 180, audioTime: 310, confidence: 1)
            ],
            gaps: [
                .init(audioStart: 30, audioEnd: 40, transcriptTime: 30),
                .init(audioStart: 100, audioEnd: 220, transcriptTime: 90)
            ]
        ))
        XCTAssertEqual(timeline.audioTime(forTranscriptTime: 29) ?? -1, 29, accuracy: 0.001)
        XCTAssertEqual(timeline.audioTime(forTranscriptTime: 30) ?? -1, 40, accuracy: 0.001)
        XCTAssertEqual(timeline.audioTime(forTranscriptTime: 89) ?? -1, 99, accuracy: 0.001)
        XCTAssertEqual(timeline.audioTime(forTranscriptTime: 90) ?? -1, 220, accuracy: 0.001)
        XCTAssertNil(timeline.transcriptTime(forAudioTime: 35))
        XCTAssertNil(timeline.transcriptTime(forAudioTime: 150))
        XCTAssertEqual(timeline.transcriptTime(forAudioTime: 221) ?? -1, 91, accuracy: 0.001)
    }

    func testLongConfirmedInsertionDoesNotInvalidateOtherwiseNormalSpeechTiming() throws {
        let timeline = try XCTUnwrap(TranscriptSynchronizationTimeline(
            anchors: [.init(transcriptTime: 0, audioTime: 0, confidence: 1),
                      .init(transcriptTime: 60, audioTime: 360, confidence: 1)],
            gaps: [.init(audioStart: 30, audioEnd: 330, transcriptTime: 30)]
        ))
        XCTAssertNil(timeline.transcriptTime(forAudioTime: 100))
        XCTAssertEqual(timeline.audioTime(forTranscriptTime: 30), 330)
        XCTAssertEqual(timeline.transcriptTime(forAudioTime: 340), 40)
    }

    func testSparseMatchesRequireEvidenceAndKeepUnmatchedRegionsUnmapped() throws {
        let anchors: [TranscriptSynchronizationAnchor] = [
            .init(transcriptTime: 0, audioTime: 0, confidence: 0.95),
            .init(transcriptTime: 20, audioTime: 20, confidence: 0.95),
            .init(transcriptTime: 40, audioTime: 50, confidence: 0.95),
            .init(transcriptTime: 60, audioTime: 70, confidence: 0.95),
            .init(transcriptTime: 80, audioTime: 390, confidence: 0.95),
            .init(transcriptTime: 100, audioTime: 410, confidence: 0.95)
        ]
        XCTAssertNil(TranscriptGapInference.infer(from: Array(anchors.prefix(3))))
        let gaps = try XCTUnwrap(TranscriptGapInference.infer(from: anchors))
        XCTAssertEqual(gaps.count, 2)
        let timeline = try XCTUnwrap(TranscriptSynchronizationTimeline(anchors: anchors, gaps: gaps))
        XCTAssertNil(timeline.transcriptTime(forAudioTime: 35))
        XCTAssertNil(timeline.audioTime(forTranscriptTime: 30))
        XCTAssertEqual(timeline.audioTime(forTranscriptTime: 40), 50)
        XCTAssertNil(timeline.transcriptTime(forAudioTime: 200))
        XCTAssertEqual(timeline.audioTime(forTranscriptTime: 80), 390)
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

    func testMatcherRejectsRepeatedPublisherPhrases() {
        let repeated = TranscriptAlignmentCandidate(
            transcriptTime: 42,
            text: "A remarkable discovery changed everything in the laboratory",
            source: .publisher
        )
        let repeatedLater = TranscriptAlignmentCandidate(
            transcriptTime: 52,
            text: "A remarkable discovery changed everything in the laboratory",
            source: .publisher
        )
        XCTAssertNil(TranscriptAlignmentMatcher.match(
            recognizedText: "A remarkable discovery changed everything in the laboratory",
            actualAudioTime: 47,
            candidates: [repeated, repeatedLater],
            expectedTranscriptTime: 45
        ))
    }

    func testMatcherFindsLargeOffsetOnlyWhenExpandedMatchIsUnambiguous() throws {
        let candidate = TranscriptAlignmentCandidate(
            transcriptTime: 100,
            text: "A remarkable discovery changed everything in the laboratory",
            source: .publisher
        )
        let match = try XCTUnwrap(TranscriptAlignmentMatcher.match(
            recognizedText: candidate.text, actualAudioTime: 400,
            candidates: [candidate], expectedTranscriptTime: 400
        ))
        XCTAssertEqual(match.transcriptTime, 100)
        let duplicate = TranscriptAlignmentCandidate(transcriptTime: 130, text: candidate.text, source: .publisher)
        XCTAssertNil(TranscriptAlignmentMatcher.match(
            recognizedText: candidate.text, actualAudioTime: 400,
            candidates: [candidate, duplicate], expectedTranscriptTime: 400
        ))
    }

    @MainActor
    func testOptOutImmediatelyRestoresOriginalTimes() throws {
        let store = TranscriptSynchronizationStore.shared
        let episodeURL = try XCTUnwrap(URL(string: "https://example.com/episode.mp3"))
        let timeline = try XCTUnwrap(TranscriptSynchronizationTimeline(anchors: [
            .init(transcriptTime: 60, audioTime: 60, confidence: 0.95),
            .init(transcriptTime: 120, audioTime: 195, confidence: 0.95)
        ]))
        store.setEnabled(true)
        XCTAssertFalse(store.hasVerifiedTimeline(for: episodeURL))
        store.install(
            timeline,
            episodeURL: episodeURL,
            mediaFingerprint: "media-a",
            transcriptRevision: "transcript-a"
        )
        XCTAssertTrue(store.hasVerifiedTimeline(for: episodeURL))
        XCTAssertEqual(store.transcriptTime(forAudioTime: 195, episodeURL: episodeURL), 120)

        store.setEnabled(false)
        XCTAssertFalse(store.hasVerifiedTimeline(for: episodeURL))
        XCTAssertEqual(store.transcriptTime(forAudioTime: 195, episodeURL: episodeURL), 195)
        XCTAssertNil(store.timeline(
            for: episodeURL,
            mediaFingerprint: "media-b",
            transcriptRevision: "transcript-a"
        ))
    }

    func testAlignmentCacheRequiresMatchingMediaAndTranscriptRevisions() async throws {
        let container = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        let cache = TranscriptAlignmentCacheActor(modelContainer: container)
        let timeline = try XCTUnwrap(TranscriptSynchronizationTimeline(anchors: [
            .init(transcriptTime: 10, audioTime: 10, confidence: 0.95),
            .init(transcriptTime: 40, audioTime: 115, confidence: 0.94),
            .init(transcriptTime: 70, audioTime: 145, confidence: 0.93)
        ]))
        let episodeURL = URL(string: "https://example.com/episode.mp3")!
        await cache.save(
            timeline,
            episodeID: "feed|episode",
            episodeURL: episodeURL,
            mediaFingerprint: "media-a",
            transcriptRevision: "transcript-a"
        )

        let matchingRevision = await cache.load(
            episodeID: "feed|episode",
            mediaFingerprint: "media-a",
            transcriptRevision: "transcript-a"
        )
        let differentMedia = await cache.load(
            episodeID: "feed|episode",
            mediaFingerprint: "media-b",
            transcriptRevision: "transcript-a"
        )
        let differentTranscript = await cache.load(
            episodeID: "feed|episode",
            mediaFingerprint: "media-a",
            transcriptRevision: "transcript-b"
        )
        XCTAssertEqual(matchingRevision, timeline)
        XCTAssertNil(differentMedia)
        XCTAssertNil(differentTranscript)
    }

    func testBackgroundSynchronizationQueueDeduplicatesAndDrainsJobs() async throws {
        let container = try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        let cache = TranscriptAlignmentCacheActor(modelContainer: container)
        let episodeURL = URL(string: "https://example.com/downloaded-episode.mp3")!

        await cache.enqueue(episodeURL: episodeURL)
        await cache.enqueue(episodeURL: episodeURL)
        let queuedBeforeRemoval = await cache.pendingJobs(limit: 10)
        let hasPendingBeforeRemoval = await cache.hasPendingJobs()
        XCTAssertEqual(queuedBeforeRemoval, [episodeURL])
        XCTAssertTrue(hasPendingBeforeRemoval)

        await cache.removeJob(for: episodeURL)
        let queuedAfterRemoval = await cache.pendingJobs(limit: 10)
        let hasPendingAfterRemoval = await cache.hasPendingJobs()
        XCTAssertEqual(queuedAfterRemoval, [])
        XCTAssertFalse(hasPendingAfterRemoval)
    }

    func testMediaFingerprintChangesWhenDownloadedBytesChange() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-sync-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data([0, 1, 2, 3, 4]).write(to: fileURL)
        let first = try TranscriptMediaFingerprint.make(for: fileURL)
        try Data([0, 1, 2, 3, 5]).write(to: fileURL)
        let second = try TranscriptMediaFingerprint.make(for: fileURL)
        XCTAssertNotEqual(first, second)
    }

    /// The current fingerprint hashes every byte (#488's partial hash is not implemented).
    func testMediaFingerprintIsStableForIdenticalBytesAndDetectsMiddleChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fingerprint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Larger than one 1 MiB read so the change lands between chunk boundaries.
        var bytes = Data((0..<(3 * 1_048_576 + 17)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let original = folder.appendingPathComponent("a.mp3")
        let copy = folder.appendingPathComponent("b.mp3")
        try bytes.write(to: original)
        try bytes.write(to: copy)
        let fingerprint = try TranscriptMediaFingerprint.make(for: original)
        XCTAssertEqual(fingerprint, try TranscriptMediaFingerprint.make(for: copy), "unchanged media is reused")
        XCTAssertEqual(fingerprint, try TranscriptMediaFingerprint.make(for: original))

        bytes[bytes.count / 2] ^= 0xFF // Same size and duration, different middle (DAI-style).
        try bytes.write(to: copy)
        XCTAssertNotEqual(fingerprint, try TranscriptMediaFingerprint.make(for: copy))

        let tiny = folder.appendingPathComponent("tiny.mp3")
        try Data().write(to: tiny)
        XCTAssertEqual(try TranscriptMediaFingerprint.make(for: tiny).count, 64)
        XCTAssertThrowsError(try TranscriptMediaFingerprint.make(for: folder.appendingPathComponent("missing.mp3")))
    }
}
