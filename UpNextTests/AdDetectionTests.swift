import XCTest
import AVFoundation
@testable import UpNext

final class AdDetectionTests: XCTestCase {
    func testOnDemandChapterEvidenceRejectsAChangedAudioVariant() async {
        let store = AdDetectionResultsStore()
        let segment = AdSegment(
            start: 20,
            end: 50,
            confidence: 0.95,
            evidence: [],
            state: .confirmed,
            episodeIdentity: "episode"
        )
        await store.store(AdDetectionSnapshot(
            episodeIdentity: "episode",
            segments: [segment],
            updatedAt: .now,
            audioVariantID: "variant-before-dai-refresh"
        ))

        let matchingVariantSegments = await store.segments(for: "episode", audioVariantID: "variant-before-dai-refresh")
        let staleVariantSegments = await store.segments(for: "episode", audioVariantID: "variant-after-dai-refresh")
        XCTAssertEqual(matchingVariantSegments, [segment])
        XCTAssertTrue(staleVariantSegments.isEmpty)
    }

    func testFusionRequiresIndependentEvidenceToConfirmAnAd() {
        let thresholds = AdDetectionThresholds.default
        let observations = [
            AdDetectionObservation(
                source: .semantic,
                range: AdTimeRange(start: 100, end: 130),
                confidence: 0.82,
                explanation: "sponsor read"
            ),
            AdDetectionObservation(
                source: .acoustic,
                range: AdTimeRange(start: 128, end: 134),
                confidence: 0.45,
                explanation: "boundary"
            )
        ]

        let segments = AdDetectionFusion.merge(
            observations: observations,
            episodeIdentity: "episode",
            thresholds: thresholds
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].state, .confirmed)
        XCTAssertEqual(segments[0].start, 100)
        XCTAssertEqual(segments[0].end, 134)
        XCTAssertGreaterThanOrEqual(segments[0].confidence, thresholds.manualSkipThreshold)
    }

    func testSingleWeakSignalRemainsBelowDisplayThreshold() {
        let observations = [
            AdDetectionObservation(
                source: .acoustic,
                range: AdTimeRange(start: 10, end: 14),
                confidence: 0.4
            )
        ]

        XCTAssertTrue(
            AdDetectionFusion.merge(observations: observations, episodeIdentity: "episode").isEmpty
        )
    }

    func testSkipPlanOnlyIncludesConfirmedStableHighConfidenceSegments() {
        let confirmed = AdSegment(
            start: 10,
            end: 30,
            confidence: 0.9,
            evidence: [],
            state: .confirmed,
            episodeIdentity: "episode"
        )
        let provisional = AdSegment(
            start: 40,
            end: 60,
            confidence: 0.99,
            evidence: [],
            state: .provisional,
            episodeIdentity: "episode"
        )
        let openEnded = AdSegment(
            start: 70,
            end: nil,
            confidence: 0.99,
            evidence: [],
            state: .confirmed,
            episodeIdentity: "episode"
        )

        let plan = AdSkipPlan(segments: [openEnded, provisional, confirmed])

        XCTAssertEqual(plan.boundaryTimes, [10])
        XCTAssertEqual(plan.segment(at: 15)?.id, confirmed.id)
        XCTAssertNil(plan.segment(at: 35))
    }

    func testDisabledEngineDoesNotInvokeProviders() async throws {
        let provider = CountingAdProvider()
        let engine = AdDetectionEngine(configuration: .default, providers: [provider])
        let request = AdDetectionRequest(
            episodeIdentity: "episode",
            mediaURL: URL(fileURLWithPath: "/tmp/episode.mp3")
        )

        let snapshot = try await engine.detect(for: request)

        XCTAssertTrue(snapshot.segments.isEmpty)
        let callCount = await provider.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testFingerprintBuilderAndMatcherTolerateSmallChanges() {
        let first = AudioFingerprintBuilder.signature(samples: Array(repeating: 0.2, count: 160))
        let second = AudioFingerprintBuilder.signature(samples: Array(repeating: 0.21, count: 160))

        XCTAssertEqual(first.count, 16)
        XCTAssertGreaterThan(AdFingerprintStore.similarity(first, second), 0.98)
    }

    func testPcmPolicyDefersForBackgroundLowPowerAndRemoteMedia() {
        XCTAssertTrue(AdDetectionWorkPolicy.shouldRunPCM(
            applicationIsActive: true,
            lowPowerModeEnabled: false,
            sourceIsLocal: true
        ))
        XCTAssertFalse(AdDetectionWorkPolicy.shouldRunPCM(
            applicationIsActive: false,
            lowPowerModeEnabled: false,
            sourceIsLocal: true
        ))
        XCTAssertFalse(AdDetectionWorkPolicy.shouldRunPCM(
            applicationIsActive: true,
            lowPowerModeEnabled: true,
            sourceIsLocal: true
        ))
        XCTAssertFalse(AdDetectionWorkPolicy.shouldRunPCM(
            applicationIsActive: true,
            lowPowerModeEnabled: false,
            sourceIsLocal: false
        ))
    }

    func testCombinedAudioProviderConsumesOneStreamingDecode() async throws {
        let audio = CountingStreamingAudioSource(chunkCount: 360)
        let provider = CombinedAudioAdvertisementSignalProvider(
            audioSource: audio,
            fingerprintStore: AdFingerprintStore(),
            podcastIdentity: nil
        )
        var configuration = AdDetectionConfiguration.default
        configuration.enabled = true
        let observations = try await provider.observations(for: AdDetectionRequest(
            episodeIdentity: "episode",
            mediaURL: URL(fileURLWithPath: "/tmp/episode.m4a"),
            range: AdTimeRange(start: 0, end: 360),
            configuration: configuration
        ))

        XCTAssertTrue(observations.isEmpty)
        XCTAssertEqual(audio.decodeCount, 1)
        XCTAssertEqual(audio.emittedChunkCount, 360)
    }

    func testRollingTranscriptRequestsShareOneInFlightOperation() async throws {
        let coordinator = AdDetectionTranscriptWorkCoordinator()
        let request = AdDetectionRequest(
            episodeIdentity: "episode",
            mediaURL: URL(fileURLWithPath: "/tmp/episode.m4a"),
            range: AdTimeRange(start: 10, end: 30)
        )
        let counter = AsyncOperationCounter()
        let results = try await withThrowingTaskGroup(of: [TranscriptDetectionLine].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try await coordinator.lines(for: request) {
                        await counter.increment()
                        try await Task.sleep(for: .milliseconds(100))
                        return [TranscriptDetectionLine(text: "sample", start: 10, end: 11)]
                    }
                }
            }
            var results: [[TranscriptDetectionLine]] = []
            for try await value in group { results.append(value) }
            return results
        }

        let invocationCount = await counter.value
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0], results[1])
        let cached = try await coordinator.lines(for: request) {
            await counter.increment()
            return []
        }
        XCTAssertEqual(cached, results[0])
        let invocationCountAfterCache = await counter.value
        XCTAssertEqual(invocationCountAfterCache, 1)
    }

    func testAbandonedSnippetCleanupIsAgeAndNameScoped() throws {
        let directory = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let old = directory.appendingPathComponent("AdDetection-test-old-\(id).caf")
        let recent = directory.appendingPathComponent("AdDetection-test-recent-\(id).caf")
        let unrelated = directory.appendingPathComponent("TranscriptSync-test-old-\(id).caf")
        defer {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: recent)
            try? FileManager.default.removeItem(at: unrelated)
        }
        try Data([1]).write(to: old)
        try Data([1]).write(to: recent)
        try Data([1]).write(to: unrelated)
        let oldDate = Date(timeIntervalSinceNow: -48 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: unrelated.path
        )

        AudioSnippetWriter.removeAbandonedTemporarySnippets(
            olderThan: Date(timeIntervalSinceNow: -24 * 60 * 60)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testAdSnippetWriterResamplesToBoundedSpeechFormat() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdDetection-source-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let sourceFormat = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        ))
        let source = try AVAudioFile(forWriting: sourceURL, settings: sourceFormat.settings)
        let sourceBuffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: 48_000 * 5
        ))
        sourceBuffer.frameLength = sourceBuffer.frameCapacity
        if let channels = sourceBuffer.floatChannelData {
            for channel in 0..<Int(sourceFormat.channelCount) {
                channels[channel].initialize(repeating: 0, count: Int(sourceBuffer.frameLength))
            }
        }
        try source.write(from: sourceBuffer)

        let snippetURL = try await AudioSnippetWriter.makeSnippet(
            from: sourceURL,
            range: AdTimeRange(start: 0, end: 5)
        )
        defer { try? FileManager.default.removeItem(at: snippetURL) }
        let snippet = try AVAudioFile(forReading: snippetURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: snippetURL.path)
        let bytes = try XCTUnwrap((attributes[.size] as? NSNumber)?.intValue)

        XCTAssertEqual(snippet.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(snippet.processingFormat.channelCount, 1)
        XCTAssertLessThan(bytes, 400_000)
    }

    func testEvaluationReportsPrecisionRecallAndBoundaryError() {
        let metrics = AdDetectionEvaluator.metrics(
            detected: [AdTimeRange(start: 101, end: 129)],
            expected: [AdTimeRange(start: 100, end: 130)]
        )

        XCTAssertGreaterThan(metrics.precision, 0.99)
        XCTAssertGreaterThan(metrics.recall, 0.9)
        XCTAssertEqual(metrics.boundaryError, 2, accuracy: 0.001)
    }
}

private final class CountingStreamingAudioSource: @unchecked Sendable, AudioAnalysisSource {
    let kind: AudioAnalysisSourceKind = .downloadedFile
    private let lock = NSLock()
    private let chunkCount: Int
    private var decodeCountStorage = 0
    private var emittedChunkCountStorage = 0

    init(chunkCount: Int) { self.chunkCount = chunkCount }

    var decodeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return decodeCountStorage
    }

    var emittedChunkCount: Int {
        lock.lock(); defer { lock.unlock() }
        return emittedChunkCountStorage
    }

    func forEachChunk(
        in range: AdTimeRange,
        windowDuration: TimeInterval,
        hopDuration: TimeInterval,
        consume: (PCMAnalysisChunk) async throws -> Void
    ) async throws {
        lock.withLock { decodeCountStorage += 1 }
        for index in 0..<chunkCount {
            try Task.checkCancellation()
            try await consume(PCMAnalysisChunk(
                start: Double(index),
                duration: 1,
                sampleRate: 48_000,
                samples: Array(repeating: 0.1, count: 64)
            ))
            lock.withLock { emittedChunkCountStorage += 1 }
        }
    }
}

private actor CountingAdProvider: AdSignalProvider {
    nonisolated let source: AdSignalSource = .semantic
    private(set) var callCount = 0

    func observations(for request: AdDetectionRequest) async throws -> [AdDetectionObservation] {
        callCount += 1
        return []
    }
}

private actor AsyncOperationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
