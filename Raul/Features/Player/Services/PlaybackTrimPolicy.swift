import Foundation

enum PlaybackTrimPolicy {
    /// Historical progress is not proof that the current completion transaction
    /// succeeded. Only an explicit replay of an episode with a durable
    /// completion date starts at zero; unfinished near-end positions survive.
    static func resolvedResumePosition(
        candidate: TimeInterval,
        duration: TimeInterval?,
        completionDate: Date? = nil,
        explicitlyReplayed: Bool = false
    ) -> TimeInterval {
        if completionDate != nil, explicitlyReplayed { return 0 }
        let position = sanitized(candidate)
        guard let duration else { return position }
        let safeDuration = sanitized(duration)
        guard safeDuration > 0 else { return position }
        return min(position, safeDuration)
    }

    static func initialPosition(
        resumePosition: TimeInterval,
        introSkipSeconds: TimeInterval,
        duration: TimeInterval?
    ) -> TimeInterval {
        let requestedPosition = max(sanitized(resumePosition), sanitized(introSkipSeconds))
        guard let duration else { return requestedPosition }

        let safeDuration = sanitized(duration)
        guard safeDuration > 0 else { return requestedPosition }
        return min(requestedPosition, safeDuration)
    }

    static func outroBoundary(
        duration: TimeInterval?,
        outroSkipSeconds: TimeInterval
    ) -> TimeInterval? {
        guard let duration else { return nil }

        let safeDuration = sanitized(duration)
        let safeOutroSkip = sanitized(outroSkipSeconds)
        guard safeDuration > 0, safeOutroSkip > 0 else { return nil }
        return max(safeDuration - safeOutroSkip, 0)
    }

    static func hasReachedOutro(
        position: TimeInterval,
        duration: TimeInterval?,
        outroSkipSeconds: TimeInterval
    ) -> Bool {
        guard let boundary = outroBoundary(
            duration: duration,
            outroSkipSeconds: outroSkipSeconds
        ) else {
            return false
        }
        return sanitized(position) >= boundary
    }

    private static func sanitized(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return max(value, 0)
    }
}
