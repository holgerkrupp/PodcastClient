import Foundation

#if DEBUG
extension Notification.Name {
    static let refreshHistoryDidChange = Notification.Name("refreshHistoryDidChange")
    static let predictedReleaseRefreshScheduleDidChange = Notification.Name("predictedReleaseRefreshScheduleDidChange")
}

enum RefreshHistoryTrigger: String, Codable, Sendable {
    case userInitiatedBulk
    case userInitiatedSingle
    case backgroundForegroundQuiet
    case backgroundAppRefresh
    case backgroundPredictedRelease
    case backgroundProcessing

    var title: String {
        switch self {
        case .userInitiatedBulk:
            return "User Initiated"
        case .userInitiatedSingle:
            return "User Initiated"
        case .backgroundForegroundQuiet:
            return "Background"
        case .backgroundAppRefresh:
            return "App Refresh"
        case .backgroundPredictedRelease:
            return "Release Refresh"
        case .backgroundProcessing:
            return "Background Processing"
        }
    }

    var detail: String {
        switch self {
        case .userInitiatedBulk:
            return "Library refresh"
        case .userInitiatedSingle:
            return "Single podcast refresh"
        case .backgroundForegroundQuiet:
            return "Foreground quiet refresh"
        case .backgroundAppRefresh:
            return "Scheduled app refresh"
        case .backgroundPredictedRelease:
            return "Scheduled predicted release refresh"
        case .backgroundProcessing:
            return "Processing task refresh"
        }
    }
}

enum RefreshHistoryPodcastResultKind: String, Codable, Sendable {
    case feedNotUpdated
    case refreshed
    case refreshFailed
    case timedOut
    case cancelled
}

struct RefreshHistoryPodcastResult: Codable, Sendable {
    let kind: RefreshHistoryPodcastResultKind
    let newEpisodeCount: Int?
    let message: String?

    static let feedNotUpdated = RefreshHistoryPodcastResult(kind: .feedNotUpdated, newEpisodeCount: nil, message: nil)
    static let timedOut = RefreshHistoryPodcastResult(kind: .timedOut, newEpisodeCount: nil, message: nil)
    static let cancelled = RefreshHistoryPodcastResult(kind: .cancelled, newEpisodeCount: nil, message: nil)

    static func refreshed(newEpisodeCount: Int) -> RefreshHistoryPodcastResult {
        RefreshHistoryPodcastResult(kind: .refreshed, newEpisodeCount: newEpisodeCount, message: nil)
    }

    static func failed(_ message: String) -> RefreshHistoryPodcastResult {
        RefreshHistoryPodcastResult(kind: .refreshFailed, newEpisodeCount: nil, message: message)
    }

    var title: String {
        switch kind {
        case .feedNotUpdated:
            return "Feed not updated"
        case .refreshed:
            if let newEpisodeCount {
                return newEpisodeCount > 0 ? "New episodes: \(newEpisodeCount)" : "Refreshed"
            }
            return "Refreshed"
        case .refreshFailed:
            return "Refresh failed"
        case .timedOut:
            return "Timed out"
        case .cancelled:
            return "Cancelled"
        }
    }
}

struct RefreshHistoryPodcastCheck: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let feedURL: String
    let result: RefreshHistoryPodcastResult

    init(title: String, feedURL: URL, result: RefreshHistoryPodcastResult) {
        self.id = feedURL.absoluteString
        self.title = title
        self.feedURL = feedURL.absoluteString
        self.result = result
    }
}

struct RefreshHistoryEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    let finishedAt: Date
    let trigger: RefreshHistoryTrigger
    let checkedPodcasts: [RefreshHistoryPodcastCheck]

    init(
        id: UUID = UUID(),
        startedAt: Date,
        finishedAt: Date,
        trigger: RefreshHistoryTrigger,
        checkedPodcasts: [RefreshHistoryPodcastCheck]
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.trigger = trigger
        self.checkedPodcasts = checkedPodcasts
    }

    var duration: TimeInterval {
        finishedAt.timeIntervalSince(startedAt)
    }

    var summary: String {
        let updated = checkedPodcasts.filter { $0.result.kind == .refreshed }.count
        let unchanged = checkedPodcasts.filter { $0.result.kind == .feedNotUpdated }.count
        let failed = checkedPodcasts.filter {
            $0.result.kind == .refreshFailed || $0.result.kind == .timedOut || $0.result.kind == .cancelled
        }.count

        var parts = ["\(checkedPodcasts.count) checked"]
        if updated > 0 {
            parts.append("\(updated) refreshed")
        }
        if unchanged > 0 {
            parts.append("\(unchanged) unchanged")
        }
        if failed > 0 {
            parts.append("\(failed) failed")
        }
        return parts.joined(separator: " • ")
    }
}

actor RefreshHistoryStore {
    static let shared = RefreshHistoryStore()

    private enum Constants {
        static let defaultsKey = "DevelopmentRefreshHistory.v1"
        static let maximumEntries = 20
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func entries() -> [RefreshHistoryEntry] {
        loadEntries()
    }

    func record(_ entry: RefreshHistoryEntry) {
        var entries = loadEntries()
        entries.insert(entry, at: 0)
        if entries.count > Constants.maximumEntries {
            entries = Array(entries.prefix(Constants.maximumEntries))
        }
        saveEntries(entries)
    }

    func clear() {
        defaults.removeObject(forKey: Constants.defaultsKey)
        notifyDidChange()
    }

    private func loadEntries() -> [RefreshHistoryEntry] {
        guard let data = defaults.data(forKey: Constants.defaultsKey) else {
            return []
        }

        return (try? decoder.decode([RefreshHistoryEntry].self, from: data)) ?? []
    }

    private func saveEntries(_ entries: [RefreshHistoryEntry]) {
        guard let data = try? encoder.encode(entries) else { return }
        defaults.set(data, forKey: Constants.defaultsKey)
        notifyDidChange()
    }

    private func notifyDidChange() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .refreshHistoryDidChange, object: nil)
        }
    }
}

struct PredictedReleaseRefreshSchedule: Codable, Sendable, Equatable {
    let scheduledAt: Date
    let title: String
    let feedURL: String
    let releaseDate: Date
    let earliestBeginDate: Date
}

actor PredictedReleaseRefreshScheduleStore {
    static let shared = PredictedReleaseRefreshScheduleStore()

    private enum Constants {
        static let defaultsKey = "DevelopmentPredictedReleaseRefreshSchedule.v1"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func schedule() -> PredictedReleaseRefreshSchedule? {
        guard let data = defaults.data(forKey: Constants.defaultsKey) else {
            return nil
        }
        return try? decoder.decode(PredictedReleaseRefreshSchedule.self, from: data)
    }

    func record(_ schedule: PredictedReleaseRefreshSchedule) {
        guard let data = try? encoder.encode(schedule) else { return }
        defaults.set(data, forKey: Constants.defaultsKey)
        notifyDidChange()
    }

    func clear() {
        defaults.removeObject(forKey: Constants.defaultsKey)
        notifyDidChange()
    }

    private func notifyDidChange() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .predictedReleaseRefreshScheduleDidChange, object: nil)
        }
    }
}
#endif
