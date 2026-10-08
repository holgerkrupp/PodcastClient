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

    @MainActor
    func testOptOutImmediatelyRestoresOriginalTimes() throws {
        let store = TranscriptSynchronizationStore.shared
        let episodeURL = try XCTUnwrap(URL(string: "https://example.com/episode.mp3"))
        let timeline = try XCTUnwrap(TranscriptSynchronizationTimeline(anchors: [
            .init(transcriptTime: 60, audioTime: 60, confidence: 0.95),
            .init(transcriptTime: 120, audioTime: 195, confidence: 0.95)
        ]))
        store.setEnabled(true)
        store.install(
            timeline,
            episodeURL: episodeURL,
            mediaFingerprint: "media-a",
            transcriptRevision: "transcript-a"
        )
        XCTAssertEqual(store.transcriptTime(forAudioTime: 195, episodeURL: episodeURL), 120)

        store.setEnabled(false)
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
}
