import Foundation

struct AdDetectionDiagnosticEvent: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let episodeIdentity: String
    let timestamp: Date
    let range: AdTimeRange
    let confidence: Double
    let source: AdSignalSource
    let message: String
}

/// A bounded in-memory diagnostics sink. Production code can inspect counts
/// without retaining audio or transcript payloads; DEBUG callers can export
/// timestamped evidence for evaluation.
actor AdDetectionDiagnostics {
    static let shared = AdDetectionDiagnostics()
    private var events: [AdDetectionDiagnosticEvent] = []
    private let limit = 512

    func record(
        episodeIdentity: String,
        range: AdTimeRange,
        confidence: Double,
        source: AdSignalSource,
        message: String
    ) {
        events.append(
            AdDetectionDiagnosticEvent(
                id: UUID(),
                episodeIdentity: episodeIdentity,
                timestamp: Date(),
                range: range,
                confidence: confidence,
                source: source,
                message: message
            )
        )
        if events.count > limit {
            events.removeFirst(events.count - limit)
        }
    }

    func snapshot(for episodeIdentity: String? = nil) -> [AdDetectionDiagnosticEvent] {
        guard let episodeIdentity else { return events }
        return events.filter { $0.episodeIdentity == episodeIdentity }
    }

    func clear() { events.removeAll(keepingCapacity: true) }
}

struct AdDetectionEvaluationMetrics: Equatable, Sendable {
    let truePositiveDuration: TimeInterval
    let falsePositiveDuration: TimeInterval
    let missedDuration: TimeInterval
    let boundaryError: TimeInterval

    var precision: Double {
        let denominator = truePositiveDuration + falsePositiveDuration
        return denominator > 0 ? truePositiveDuration / denominator : 1
    }

    var recall: Double {
        let denominator = truePositiveDuration + missedDuration
        return denominator > 0 ? truePositiveDuration / denominator : 1
    }
}

enum AdDetectionEvaluator {
    static func metrics(
        detected: [AdTimeRange],
        expected: [AdTimeRange]
    ) -> AdDetectionEvaluationMetrics {
        let truePositive = detected.reduce(0) { total, candidate in
            total + expected.reduce(0) { overlap, target in overlap + overlapDuration(candidate, target) }
        }
        let detectedDuration = detected.reduce(0) { $0 + ($1.duration ?? 0) }
        let expectedDuration = expected.reduce(0) { $0 + ($1.duration ?? 0) }
        let falsePositive = max(detectedDuration - truePositive, 0)
        let missed = max(expectedDuration - truePositive, 0)
        let boundaryError = zip(detected, expected).reduce(0) { total, pair in
            total + abs(pair.0.start - pair.1.start) + abs((pair.0.end ?? pair.0.start) - (pair.1.end ?? pair.1.start))
        }
        return AdDetectionEvaluationMetrics(
            truePositiveDuration: truePositive,
            falsePositiveDuration: falsePositive,
            missedDuration: missed,
            boundaryError: boundaryError
        )
    }

    private static func overlapDuration(_ lhs: AdTimeRange, _ rhs: AdTimeRange) -> TimeInterval {
        guard let lhsEnd = lhs.end, let rhsEnd = rhs.end else { return 0 }
        return max(0, min(lhsEnd, rhsEnd) - max(lhs.start, rhs.start))
    }
}

