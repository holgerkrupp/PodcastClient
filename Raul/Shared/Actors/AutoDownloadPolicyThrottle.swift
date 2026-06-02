import Foundation

actor AutoDownloadPolicyThrottle {
    static let shared = AutoDownloadPolicyThrottle()

    private let minimumInterval: TimeInterval = 15 * 60
    private var lastStartedAtByFeed: [URL: Date] = [:]
    private var inFlightFeeds = Set<URL>()

    private init() {}

    func begin(feed: URL, force: Bool, now: Date = Date()) -> AutoDownloadPolicyThrottleDecision {
        if inFlightFeeds.contains(feed) {
            return .skip(reason: "already-in-flight")
        }

        if force == false,
           let lastStartedAt = lastStartedAtByFeed[feed] {
            let elapsed = now.timeIntervalSince(lastStartedAt)
            if elapsed < minimumInterval {
                return .skip(reason: "cooldown-\(Int(minimumInterval - elapsed))s-remaining")
            }
        }

        inFlightFeeds.insert(feed)
        lastStartedAtByFeed[feed] = now
        return .run
    }

    func finish(feed: URL) {
        inFlightFeeds.remove(feed)
    }
}

enum AutoDownloadPolicyThrottleDecision: Sendable {
    case run
    case skip(reason: String)
}
