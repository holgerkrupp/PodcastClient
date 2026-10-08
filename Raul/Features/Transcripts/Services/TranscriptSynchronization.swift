import Foundation
import Observation

struct TranscriptSynchronizationAnchor: Codable, Hashable, Sendable {
    let transcriptTime: TimeInterval
    let audioTime: TimeInterval
    let confidence: Double
}

struct TranscriptAudioGap: Codable, Hashable, Sendable {
    let audioStart: TimeInterval
    let audioEnd: TimeInterval
    let transcriptTime: TimeInterval
}

/// A monotonic, piecewise mapping between publisher-caption time and played-audio time.
/// Transcript rows remain untouched; a gap maps to no active caption instead of advancing early.
struct TranscriptSynchronizationTimeline: Codable, Hashable, Sendable {
    let anchors: [TranscriptSynchronizationAnchor]
    let gaps: [TranscriptAudioGap]

    init?(anchors: [TranscriptSynchronizationAnchor], gaps: [TranscriptAudioGap] = []) {
        let ordered = anchors.sorted { $0.transcriptTime < $1.transcriptTime }
        guard ordered.count >= 2,
              ordered.allSatisfy({
                  $0.transcriptTime.isFinite && $0.audioTime.isFinite
                      && $0.transcriptTime >= 0 && $0.audioTime >= 0
                      && $0.confidence.isFinite && (0...1).contains($0.confidence)
              }) else { return nil }
        for pair in zip(ordered, ordered.dropFirst()) {
            let transcriptDelta = pair.1.transcriptTime - pair.0.transcriptTime
            let audioDelta = pair.1.audioTime - pair.0.audioTime
            guard transcriptDelta > 0, audioDelta > 0 else { return nil }
            let slope = audioDelta / transcriptDelta
            guard (0.25...4).contains(slope) else { return nil }
        }
        let orderedGaps = gaps.sorted { $0.audioStart < $1.audioStart }
        guard orderedGaps.allSatisfy({
            $0.audioStart.isFinite && $0.audioEnd.isFinite && $0.transcriptTime.isFinite
                && $0.audioStart >= 0 && $0.audioEnd > $0.audioStart && $0.transcriptTime >= 0
        }), zip(orderedGaps, orderedGaps.dropFirst()).allSatisfy({ $0.audioEnd <= $1.audioStart }) else {
            return nil
        }
        self.anchors = ordered
        self.gaps = orderedGaps
    }

    func transcriptTime(forAudioTime time: TimeInterval) -> TimeInterval? {
        guard time.isFinite, time >= 0,
              gaps.contains(where: { time >= $0.audioStart && time < $0.audioEnd }) == false else {
            return nil
        }
        return interpolate(time, x: \.audioTime, y: \.transcriptTime)
    }

    func audioTime(forTranscriptTime time: TimeInterval) -> TimeInterval? {
        guard time.isFinite, time >= 0 else { return nil }
        return interpolate(time, x: \.transcriptTime, y: \.audioTime)
    }

    private func interpolate(
        _ value: TimeInterval,
        x: KeyPath<TranscriptSynchronizationAnchor, TimeInterval>,
        y: KeyPath<TranscriptSynchronizationAnchor, TimeInterval>
    ) -> TimeInterval {
        guard let first = anchors.first, let last = anchors.last else { return value }
        if value <= first[keyPath: x] {
            return value + first[keyPath: y] - first[keyPath: x]
        }
        if value >= last[keyPath: x] {
            return value + last[keyPath: y] - last[keyPath: x]
        }
        for (left, right) in zip(anchors, anchors.dropFirst()) {
            let lower = left[keyPath: x]
            let upper = right[keyPath: x]
            guard value >= lower, value <= upper else { continue }
            let fraction = (value - lower) / (upper - lower)
            return left[keyPath: y] + fraction * (right[keyPath: y] - left[keyPath: y])
        }
        return value
    }
}

struct TranscriptAlignmentCandidate: Sendable {
    let transcriptTime: TimeInterval
    let text: String
    let source: CachedTranscriptSource?
}

struct TranscriptAlignmentMatcher {
    /// Match short ASR observations only against nearby publisher rows. A missing or
    /// ambiguous provenance is rejected before text matching.
    static func match(
        recognizedText: String,
        actualAudioTime: TimeInterval,
        candidates: [TranscriptAlignmentCandidate],
        expectedTranscriptTime: TimeInterval
    ) -> TranscriptSynchronizationAnchor? {
        guard actualAudioTime.isFinite, actualAudioTime >= 0,
              expectedTranscriptTime.isFinite,
              let observed = normalizedTokens(recognizedText),
              informativeTokenCount(observed) >= 3 else { return nil }

        let eligible = candidates.compactMap { candidate -> (TranscriptAlignmentCandidate, Double)? in
            guard candidate.source == .publisher,
                  abs(candidate.transcriptTime - expectedTranscriptTime) <= 90,
                  let target = normalizedTokens(candidate.text),
                  informativeTokenCount(target) >= 3 else { return nil }
            let score = tokenSimilarity(observed, target)
            return (candidate, score)
        }.sorted { $0.1 > $1.1 }
        guard let best = eligible.first, best.1 >= 0.78 else { return nil }
        if eligible.count > 1, best.1 - eligible[1].1 < 0.08 { return nil }
        return TranscriptSynchronizationAnchor(
            transcriptTime: best.0.transcriptTime,
            audioTime: actualAudioTime,
            confidence: best.1
        )
    }

    private static func normalizedTokens(_ text: String) -> [String]? {
        let tokens = text.lowercased().components(
            separatedBy: CharacterSet.alphanumerics.inverted
        ).filter { $0.isEmpty == false }
        return tokens.isEmpty ? nil : tokens
    }

    private static func informativeTokenCount(_ tokens: [String]) -> Int {
        Set(tokens.filter { $0.count > 2 && !commonWords.contains($0) }).count
    }

    private static func tokenSimilarity(_ left: [String], _ right: [String]) -> Double {
        let leftSet = Set(left)
        let rightSet = Set(right)
        let intersection = leftSet.intersection(rightSet).count
        guard intersection > 0 else { return 0 }
        let overlap = Double(intersection) / Double(max(leftSet.count, rightSet.count))
        let ordered = Double(longestCommonSubsequence(left, right)) / Double(max(left.count, right.count))
        return overlap * 0.55 + ordered * 0.45
    }

    private static func longestCommonSubsequence(_ left: [String], _ right: [String]) -> Int {
        var previous = Array(repeating: 0, count: right.count + 1)
        for lhs in left {
            var current = Array(repeating: 0, count: right.count + 1)
            for (index, rhs) in right.enumerated() {
                current[index + 1] = lhs == rhs
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            previous = current
        }
        return previous[right.count]
    }

    private static let commonWords: Set<String> = [
        "the", "and", "that", "this", "with", "you", "for", "are", "was", "have", "from",
        "but", "not", "what", "when", "where", "your", "our", "they", "them", "then"
    ]
}

/// Main-actor snapshot used synchronously by transcript views and seek controls.
/// Disabling it drops active mappings in the same turn; cached data can be reloaded later.
@MainActor
@Observable
final class TranscriptSynchronizationStore {
    static let shared = TranscriptSynchronizationStore()

    private(set) var isEnabled = false
    private var timelinesByEpisodeKey: [String: TranscriptSynchronizationTimeline] = [:]

    private init() {}

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func install(
        _ timeline: TranscriptSynchronizationTimeline,
        episodeURL: URL,
        lines: [TranscriptLineAndTime]
    ) -> Bool {
        guard lines.isEmpty == false,
              lines.allSatisfy({ $0.transcriptSource == .publisher }) else { return false }
        timelinesByEpisodeKey[episodeURL.absoluteString] = timeline
        return true
    }

    func removeTimeline(for episodeURL: URL) {
        timelinesByEpisodeKey.removeValue(forKey: episodeURL.absoluteString)
    }

    func transcriptTime(forAudioTime time: TimeInterval, episodeURL: URL?) -> TimeInterval? {
        guard isEnabled, let episodeURL,
              let timeline = timelinesByEpisodeKey[episodeURL.absoluteString] else { return time }
        return timeline.transcriptTime(forAudioTime: time)
    }

    func audioTime(forTranscriptTime time: TimeInterval, episodeURL: URL?) -> TimeInterval? {
        guard isEnabled, let episodeURL,
              let timeline = timelinesByEpisodeKey[episodeURL.absoluteString] else { return time }
        return timeline.audioTime(forTranscriptTime: time)
    }
}
