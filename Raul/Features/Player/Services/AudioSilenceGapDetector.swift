import Foundation

struct AudioSilenceGapDetector: Sendable {
    let level: SilenceGapReductionLevel

    private(set) var isReducingSilence = false
    private var accumulatedSilenceDuration: TimeInterval = 0

    init(level: SilenceGapReductionLevel = .low) {
        self.level = level
    }

    mutating func observe(decibels: Float, duration: TimeInterval) -> Bool? {
        guard duration > 0 else { return nil }

        if decibels <= level.silenceThresholdDecibels {
            accumulatedSilenceDuration += duration
            if isReducingSilence == false,
               accumulatedSilenceDuration >= level.minimumSilenceDuration {
                isReducingSilence = true
                return true
            }
        } else {
            accumulatedSilenceDuration = 0
            if isReducingSilence {
                isReducingSilence = false
                return false
            }
        }

        return nil
    }

    mutating func reset() -> Bool? {
        accumulatedSilenceDuration = 0
        guard isReducingSilence else { return nil }
        isReducingSilence = false
        return false
    }

    static func silenceReducedRate(
        for playbackRate: Float,
        level: SilenceGapReductionLevel = .low
    ) -> Float {
        min(3.0, max(playbackRate * level.rateMultiplier, playbackRate + level.minimumRateIncrease))
    }
}

private extension SilenceGapReductionLevel {
    var silenceThresholdDecibels: Float {
        switch self {
        case .low: return -52
        case .medium: return -48
        case .high: return -45
        }
    }

    var minimumSilenceDuration: TimeInterval {
        switch self {
        case .low: return 0.65
        case .medium: return 0.45
        case .high: return 0.35
        }
    }

    var rateMultiplier: Float {
        switch self {
        case .low: return 1.25
        case .medium: return 1.5
        case .high: return 1.8
        }
    }

    var minimumRateIncrease: Float {
        switch self {
        case .low: return 0.15
        case .medium: return 0.3
        case .high: return 0.4
        }
    }
}
