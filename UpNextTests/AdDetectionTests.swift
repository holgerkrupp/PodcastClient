import XCTest
@testable import UpNext

final class AdDetectionTests: XCTestCase {
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

private actor CountingAdProvider: AdSignalProvider {
    nonisolated let source: AdSignalSource = .semantic
    private(set) var callCount = 0

    func observations(for request: AdDetectionRequest) async throws -> [AdDetectionObservation] {
        callCount += 1
        return []
    }
}
