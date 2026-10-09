import XCTest
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
