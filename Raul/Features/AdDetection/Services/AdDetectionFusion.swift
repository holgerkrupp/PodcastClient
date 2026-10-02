import Foundation

enum AdDetectionFusion {
    private static let sourceWeights: [AdSignalSource: Double] = [
        .semantic: 1.0,
        .transcript: 0.82,
        .fingerprint: 0.95,
        .publisherMetadata: 0.55,
        .acoustic: 0.42
    ]

    static func merge(
        observations: [AdDetectionObservation],
        episodeIdentity: String,
        thresholds: AdDetectionThresholds = .default,
        mergeGap: TimeInterval = 4
    ) -> [AdSegment] {
        let candidates = observations
            .filter { $0.kind == .advertisement && $0.range.isValid && $0.confidence > 0 }
            .sorted { $0.range.start < $1.range.start }
        let negativeEvidence = observations.filter {
            $0.kind == .negativeEvidence && $0.range.isValid && $0.confidence > 0
        }

        var clusters: [[AdDetectionObservation]] = []
        for candidate in candidates {
            guard let lastIndex = clusters.indices.last else {
                clusters.append([candidate])
                continue
            }

            let last = clusters[lastIndex]
            let lastEnd = last.compactMap(\.range.end).max() ?? .greatestFiniteMagnitude
            let overlaps = candidate.range.start <= lastEnd + mergeGap
            if overlaps {
                clusters[lastIndex].append(candidate)
            } else {
                clusters.append([candidate])
            }
        }

        return clusters.compactMap { cluster in
            guard let first = cluster.first else { return nil }
            let start = cluster.map(\.range.start).min() ?? first.range.start
            let ends = cluster.compactMap { $0.range.end }
            let end = ends.max()
            let sourceContributions = cluster.reduce(into: [AdSignalSource: Double]()) { result, observation in
                let weight = sourceWeights[observation.source] ?? 0.5
                let contribution = min(max(observation.confidence, 0), 1) * weight
                result[observation.source] = max(result[observation.source] ?? 0, contribution)
            }
            let positiveConfidence = 1 - sourceContributions.values.reduce(1) { partial, contribution in
                partial * (1 - min(max(contribution, 0), 0.98))
            }
            let negativePenalty = negativeEvidence
                .filter { $0.range.overlaps(AdTimeRange(start: start, end: end), tolerance: 1) }
                .map(\.confidence)
                .max() ?? 0
            let confidence = positiveConfidence * (1 - min(negativePenalty * 0.65, 0.65))
            let distinctSources = Set(cluster.map(\.source))
            let hasStrongSemanticSignal = sourceContributions[.semantic, default: 0] >= 0.72
            let hasStrongFingerprintSignal = sourceContributions[.fingerprint, default: 0] >= 0.68
            let state: AdSegmentState = confidence >= thresholds.displayThreshold
                && (distinctSources.count >= 2 || hasStrongSemanticSignal || hasStrongFingerprintSignal)
                ? .confirmed
                : .provisional

            return AdSegment(
                start: start,
                end: end,
                confidence: confidence,
                evidence: cluster.map(\.evidence),
                state: state,
                episodeIdentity: episodeIdentity
            )
        }
        .filter { $0.confidence >= thresholds.displayThreshold }
        .sorted { $0.start < $1.start }
    }
}
