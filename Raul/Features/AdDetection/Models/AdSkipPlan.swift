import Foundation

/// In-memory boundary actions for confirmed advertisements. It mirrors
/// ChapterSkipPlan so automatic skipping never performs storage or model work
/// at the exact playback boundary.
struct AdSkipPlan: Equatable, Sendable {
    let segments: [AdSegment]

    init(segments: [AdSegment], threshold: Double = AdDetectionThresholds.default.automaticSkipThreshold) {
        self.segments = segments
            .filter { $0.state == .confirmed && $0.confidence >= threshold && $0.hasKnownStableEnd }
            .sorted { $0.start < $1.start }
    }

    var boundaryTimes: [TimeInterval] { segments.map(\.start) }

    func segment(at position: TimeInterval) -> AdSegment? {
        segments.last(where: { $0.contains(position) })
    }
}

