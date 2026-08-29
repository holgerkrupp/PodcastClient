import Foundation
import SwiftData

struct AppReviewPromptState: Equatable {
    var lastRequestedVersion: String?
    var lastRequestedAt: Date?
}

enum AppReviewPromptPolicy {
    static let minimumListeningSeconds: TimeInterval = 100 * 60 * 60
    static let minimumForegroundDuration: TimeInterval = 40
    static let requestCooldown: TimeInterval = 180 * 24 * 60 * 60

    static func shouldRequestReview(
        listeningSeconds: TimeInterval,
        foregroundDuration: TimeInterval,
        isSceneActive: Bool,
        hasBlockingPresentation: Bool,
        currentVersion: String,
        state: AppReviewPromptState,
        now: Date
    ) -> Bool {
        guard listeningSeconds > minimumListeningSeconds else { return false }
        guard foregroundDuration >= minimumForegroundDuration else { return false }
        guard isSceneActive, hasBlockingPresentation == false else { return false }
        guard state.lastRequestedVersion != currentVersion else { return false }

        if let lastRequestedAt = state.lastRequestedAt,
           now.timeIntervalSince(lastRequestedAt) < requestCooldown {
            return false
        }

        return true
    }
}

struct AppReviewPromptStore {
    private enum Keys {
        static let lastRequestedVersion = "appReviewPrompt.lastRequestedVersion"
        static let lastRequestedAt = "appReviewPrompt.lastRequestedAt"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var state: AppReviewPromptState {
        AppReviewPromptState(
            lastRequestedVersion: defaults.string(forKey: Keys.lastRequestedVersion),
            lastRequestedAt: defaults.object(forKey: Keys.lastRequestedAt) as? Date
        )
    }

    func recordRequest(version: String, at date: Date) {
        defaults.set(version, forKey: Keys.lastRequestedVersion)
        defaults.set(date, forKey: Keys.lastRequestedAt)
    }
}

actor AppReviewLifetimeListeningLoader {
    private let legacyContainer: ModelContainer
    private let userStateContainer: ModelContainer?
    private let useSyncedStore: Bool

    init(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer?,
        useSyncedStore: Bool
    ) {
        self.legacyContainer = legacyContainer
        self.userStateContainer = userStateContainer
        self.useSyncedStore = useSyncedStore
    }

    func totalSeconds() -> TimeInterval {
        let legacyTotal = legacyLifetimeSeconds()

        guard useSyncedStore, let syncedTotal = syncedLifetimeSeconds() else {
            return legacyTotal
        }

        // During migration both stores can describe the same listening. The
        // larger complete view is authoritative; adding them would double-count.
        return max(legacyTotal, syncedTotal)
    }

    private func syncedLifetimeSeconds() -> TimeInterval? {
        guard let userStateContainer else { return nil }

        let context = ModelContext(userStateContainer)
        let baselineRows = (try? context.fetch(
            FetchDescriptor<ListeningBaselineSync>()
        )) ?? []
        let historyRows = (try? context.fetch(
            FetchDescriptor<ListeningHistorySync>()
        )) ?? []

        let baseline: TimeInterval? = {
            guard baselineRows.isEmpty == false else { return nil }
            let perFeed = baselineRows.filter {
                $0.feedURL != ListeningBaselineSync.allPodcastsFeedURL
            }
            let scopedRows = perFeed.isEmpty ? baselineRows : perFeed
            return scopedRows.reduce(0) { $0 + max(0, $1.totalSeconds) }
        }()

        let liveSeconds = ListeningHistoryAggregation.globalStatistics(
            from: historyRows.filter { $0.isLegacyMigrated == false }
        ).totalSeconds
        let migratedSeconds = ListeningHistoryAggregation.globalStatistics(
            from: historyRows.filter(\.isLegacyMigrated)
        ).totalSeconds

        guard baseline != nil || liveSeconds > 0 || migratedSeconds > 0 else {
            return nil
        }

        return AccountListeningTotals.lifetimeSeconds(
            baselineSeconds: baseline,
            liveSeconds: liveSeconds,
            migratedSeconds: migratedSeconds
        )
    }

    private func legacyLifetimeSeconds() -> TimeInterval {
        let context = ModelContext(legacyContainer)
        let yearPeriod = PlaySessionSummaryPeriod.year.rawValue
        let summaryDescriptor = FetchDescriptor<PlaySessionSummary>(
            predicate: #Predicate { $0.periodKind == yearPeriod }
        )
        let summaries = (try? context.fetch(summaryDescriptor)) ?? []

        if summaries.isEmpty == false {
            return summaries.reduce(0) { $0 + max(0, $1.totalSeconds ?? 0) }
        }

        let sessions = (try? context.fetch(FetchDescriptor<PlaySession>())) ?? []
        return sessions.reduce(0) { total, session in
            guard let start = session.startTime else { return total }
            let end = session.endTime ?? start
            return total + max(0, end.timeIntervalSince(start))
        }
    }
}
