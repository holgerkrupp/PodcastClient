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

        let editorial = editorialCandidates
            .filter { candidate in
                guard candidate.start.isFinite, candidate.start >= 0,
                      candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    return false
                }
                return ads.contains { $0.start <= candidate.start && candidate.start < ($0.end ?? .greatestFiniteMagnitude) } == false
            }
            .sorted { $0.start < $1.start }
            .reduce(into: [GeneratedChapterProposal]()) { result, candidate in
                let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard title.isEmpty == false else { return }
                if let previous = result.last,
                   candidate.start - previous.start < minimumEditorialSeparation {
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

        return (editorial + ads)
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.kind == .advertisement
            }
    }

    static func shouldGenerateAlongsideExistingChapters(_ types: [MarkerType]) -> Bool {
        let timelineTypes = Set(types).subtracting([.bookmark, .soundbite])
        guard timelineTypes.isEmpty == false else { return true }
        return timelineTypes.allSatisfy { $0 == .ai || $0 == .advertisement || $0 == .extracted }
    }

    private static func minPositiveEnd(_ end: TimeInterval?, duration: TimeInterval?) -> TimeInterval? {
        guard let end, end.isFinite, end > 0 else { return nil }
        if let duration, duration.isFinite, duration > 0 {
            return min(end, duration)
        }
        return end
    }
}
