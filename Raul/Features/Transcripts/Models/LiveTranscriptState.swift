import Foundation

/// Finalized on-device results for a partially analyzed episode. Tentative
/// recognition stays in memory and never enters this persisted state.
struct LiveTranscriptState: Codable, Sendable {
    struct FinalWindow: Sendable {
        let coverage: Coverage
        let cues: [Cue]
    }
    struct Coverage: Codable, Sendable, Equatable {
        var start: TimeInterval
        var end: TimeInterval
    }
    struct Cue: Codable, Sendable, Identifiable, Hashable {
        let id: UUID
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        let spans: [TranscriptTimedSpan]
    }
    var mediaFingerprint: String
    var coverage: [Coverage] = []
    var cues: [Cue] = []

    mutating func append(cues incoming: [Cue], coverage interval: Coverage) {
        guard interval.start.isFinite, interval.end.isFinite, interval.start >= 0, interval.end > interval.start else { return }
        let sorted = (coverage + [interval]).sorted { $0.start < $1.start }
        var merged: [Coverage] = []
        for current in sorted {
            if let last = merged.last, current.start <= last.end + 0.01 {
                merged[merged.count - 1].end = max(last.end, current.end)
            } else {
                merged.append(current)
            }
        }
        coverage = merged
        for cue in incoming where cue.start.isFinite && cue.end.isFinite && cue.end > cue.start
            && cue.start >= interval.start - 0.05 && cue.end <= interval.end + 0.15 {
            // Revisions for the same timed range replace in place. Unmatched
            // older speech is retained rather than inferred to be deleted.
            if let index = cues.firstIndex(where: { abs($0.start - cue.start) < 0.3 && abs($0.end - cue.end) < 0.3 }) {
                cues[index] = Cue(id: cues[index].id, text: cue.text, start: cue.start, end: cue.end, spans: cue.spans)
            } else {
                cues.append(cue)
            }
        }
        cues.sort { $0.start < $1.start }
    }

    func contains(_ time: TimeInterval) -> Bool {
        coverage.contains { time >= $0.start && time < $0.end }
    }
}
