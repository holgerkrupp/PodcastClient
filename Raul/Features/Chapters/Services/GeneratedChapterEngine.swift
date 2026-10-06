import Foundation

enum GeneratedChapterKind: String, Codable, Sendable {
    case editorial
    case advertisement
}

struct GeneratedEditorialChapterCandidate: Equatable, Sendable {
    let title: String
    let start: TimeInterval

    init(title: String, start: TimeInterval) {
        self.title = title
        self.start = start
    }
}

struct GeneratedAdvertisementCandidate: Equatable, Sendable {
    let start: TimeInterval
}

struct GeneratedChapterProposal: Equatable, Sendable {
    let kind: GeneratedChapterKind
    let title: String
    let start: TimeInterval
    let end: TimeInterval?
    let confidence: Double
    let audioVariantID: String?
}

/// Merges semantic transcript boundaries with already-confirmed ad ranges.
/// This layer is deterministic: ML work happens in the existing transcript and
/// ad-detection services, while precedence and persistence decisions stay here.
enum GeneratedChapterEngine {
    static let minimumEditorialSeparation: TimeInterval = 5 * 60

    static func makeProposals(
        editorialCandidates: [GeneratedEditorialChapterCandidate],
        advertisementCandidates: [GeneratedAdvertisementCandidate] = [],
        adSegments: [AdSegment],
        existingTypes: [MarkerType],
        episodeDuration: TimeInterval?,
        audioVariantID: String?,
        adConfidenceThreshold: Double = AdDetectionThresholds.default.displayThreshold
    ) -> [GeneratedChapterProposal] {
        guard shouldGenerateAlongsideExistingChapters(existingTypes) else { return [] }

        let ads = adSegments
            .filter {
                $0.state == .confirmed
                    && $0.confidence >= adConfidenceThreshold
                    && $0.hasKnownStableEnd
            }
            .compactMap { segment -> GeneratedChapterProposal? in
                let start = max(segment.start, 0)
                let end = minPositiveEnd(segment.end, duration: episodeDuration)
                guard let end, end > start else { return nil }
                return GeneratedChapterProposal(
                    kind: .advertisement,
                    title: "Advertisement",
                    start: start,
                    end: end,
                    confidence: segment.confidence,
                    audioVariantID: audioVariantID
                )
            }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return (lhs.end ?? .greatestFiniteMagnitude) < (rhs.end ?? .greatestFiniteMagnitude)
            }

        let semanticAds = advertisementCandidates
            .filter { $0.start.isFinite && $0.start >= 0 }
            .sorted { $0.start < $1.start }
        var semanticRanges: [(TimeInterval, TimeInterval)] = []
        for candidate in semanticAds {
            let start = candidate.start
            guard semanticRanges.contains(where: { $0.0 <= start && start < $0.1 }) == false else { continue }
            let resume = editorialCandidates
                .filter { $0.start > start }
                .map(\.start)
                .min()
            guard let end = resume ?? episodeDuration, end > start else { continue }
            semanticRanges.append((start, end))
        }
        let editorial = editorialCandidates
            .filter { candidate in
                guard candidate.start.isFinite, candidate.start >= 0,
                      candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    return false
                }
                let coveredByConfirmedAd = ads.contains {
                    $0.start <= candidate.start && candidate.start < ($0.end ?? .greatestFiniteMagnitude)
                }
                let coveredBySemanticAd = semanticRanges.contains { $0.0 <= candidate.start && candidate.start < $0.1 }
                return coveredByConfirmedAd == false && coveredBySemanticAd == false
            }
            .sorted { $0.start < $1.start }
            .reduce(into: [GeneratedChapterProposal]()) { result, candidate in
                let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard title.isEmpty == false else { return }
                if let previous = result.last,
                   candidate.start - previous.start < minimumEditorialSeparation,
                   semanticRanges.contains(where: { $0.1 == candidate.start }) == false {
                    return
                }
                result.append(
                    GeneratedChapterProposal(
                        kind: .editorial,
                        title: title,
                        start: candidate.start,
                        end: nil,
                        confidence: 0.75,
                        audioVariantID: audioVariantID
                    )
                )
            }

        let semanticAdProposals = semanticRanges.compactMap { start, end -> GeneratedChapterProposal? in
            let overlapsConfirmed = ads.contains { $0.start <= end && start <= ($0.end ?? .greatestFiniteMagnitude) }
            guard overlapsConfirmed == false else { return nil }
            return GeneratedChapterProposal(
                kind: .advertisement,
                title: "Advertisement",
                start: start,
                end: end,
                confidence: 0.7,
                audioVariantID: audioVariantID
            )
        }

        return (editorial + ads + semanticAdProposals)
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.kind == .advertisement
            }
    }

    static func shouldGenerateAlongsideExistingChapters(_ types: [MarkerType]) -> Bool {
        let timelineTypes = Set(types).subtracting([.bookmark, .soundbite])
        guard timelineTypes.isEmpty == false else { return true }
        return timelineTypes.allSatisfy { $0 == .ai || $0 == .extracted }
    }

    private static func minPositiveEnd(_ end: TimeInterval?, duration: TimeInterval?) -> TimeInterval? {
        guard let end, end.isFinite, end > 0 else { return nil }
        if let duration, duration.isFinite, duration > 0 {
            return min(end, duration)
        }
        return end
    }
}
