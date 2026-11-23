import Foundation

#if DEBUG
extension Notification.Name {
    static let refreshHistoryDidChange = Notification.Name("refreshHistoryDidChange")
    static let predictedReleaseRefreshScheduleDidChange = Notification.Name("predictedReleaseRefreshScheduleDidChange")
}

enum RefreshHistoryTrigger: String, Codable, Sendable, Equatable {
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

enum RefreshHistoryPodcastResultKind: String, Codable, Sendable, Equatable {
    case feedNotUpdated
    case refreshed
    case refreshFailed
    case timedOut
    case cancelled
}

enum RefreshHistoryStatus: String, Codable, Sendable, Equatable {
    case inProgress
    case completed
    case cancelled
    case failed
    case interrupted

    var title: String {
        switch self {
        case .inProgress:
            return "In progress"
        case .completed:
            return "Completed"
        case .cancelled:
            return "Cancelled"
        case .failed:
            return "Failed"
        case .interrupted:
            return "Interrupted"
        }
    }
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
        RefreshHistoryPodcastResult(
            kind: .refreshFailed,
            newEpisodeCount: nil,
            message: privacySafeFailureMessage(message)
        )
    }

    private static func privacySafeFailureMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              trimmed.count <= 160,
              trimmed.contains("http://") == false,
              trimmed.contains("https://") == false,
              trimmed.contains("www.") == false,
              trimmed.contains("token=") == false,
              trimmed.contains("password=") == false else {
            return "Feed refresh failed"
        }
        return trimmed
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
        let safeFeedURL = feedURL.podcastNonSecretURL
        self.id = safeFeedURL.absoluteString
        self.title = title
        self.feedURL = safeFeedURL.absoluteString
        self.result = result
    }
}

struct RefreshHistoryEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    var finishedAt: Date?
    let trigger: RefreshHistoryTrigger
    var status: RefreshHistoryStatus
    var completed: Int
    var total: Int
    var checkedPodcasts: [RefreshHistoryPodcastCheck]
    var diagnostics: RefreshHistoryDiagnostics?

    private enum CodingKeys: String, CodingKey {
        case id
        case startedAt
        case finishedAt
        case trigger
        case status
        case completed
        case total
        case checkedPodcasts
        case diagnostics
    }

    init(
        id: UUID = UUID(),
        startedAt: Date,
        finishedAt: Date? = nil,
        trigger: RefreshHistoryTrigger,
        checkedPodcasts: [RefreshHistoryPodcastCheck],
        diagnostics: RefreshHistoryDiagnostics? = nil,
        status: RefreshHistoryStatus = .completed,
        completed: Int? = nil,
        total: Int? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.trigger = trigger
        self.status = status
        self.completed = max(0, completed ?? checkedPodcasts.count)
        self.total = max(0, total ?? checkedPodcasts.count)
        self.checkedPodcasts = checkedPodcasts
        self.diagnostics = diagnostics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.finishedAt = finishedAt
        self.trigger = try container.decode(RefreshHistoryTrigger.self, forKey: .trigger)
        self.status = try container.decodeIfPresent(RefreshHistoryStatus.self, forKey: .status)
            ?? (finishedAt == nil ? .inProgress : .completed)
        let checkedPodcasts = try container.decodeIfPresent(
            [RefreshHistoryPodcastCheck].self,
            forKey: .checkedPodcasts
        ) ?? []
        self.checkedPodcasts = checkedPodcasts
        self.completed = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .completed) ?? checkedPodcasts.count
        )
        self.total = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .total) ?? checkedPodcasts.count
        )
        self.diagnostics = try container.decodeIfPresent(
            RefreshHistoryDiagnostics.self,
            forKey: .diagnostics
        )
    }

    var duration: TimeInterval {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var isActive: Bool {
        status == .inProgress
    }

    var summary: String {
        let updated = checkedPodcasts.filter { $0.result.kind == .refreshed }.count
        let unchanged = checkedPodcasts.filter { $0.result.kind == .feedNotUpdated }.count
        let failed = checkedPodcasts.filter {
            $0.result.kind == .refreshFailed || $0.result.kind == .timedOut || $0.result.kind == .cancelled
        }.count

        if isActive {
            return total > 0 ? "\(completed) of \(total) checked" : "Preparing refresh…"
        }

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

struct RefreshHistoryDiagnostics: Codable, Sendable {
    let candidatePreparationDuration: TimeInterval
    let processCPUTime: TimeInterval
    let stopReason: String
    let candidates: Int
    let remaining: Int
}

actor RefreshHistoryStore {
    static let shared = RefreshHistoryStore()

    private enum Constants {
        static let defaultsKey = "DevelopmentRefreshHistory.v1"
        static let maximumEntries = 20
        static let persistenceDelayNanoseconds: UInt64 = 200_000_000
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedEntries: [RefreshHistoryEntry]?
    private var persistenceTask: Task<Void, Never>?
    private var persistencePending = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    init(suiteName: String) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    func entries() -> [RefreshHistoryEntry] {
        recoverUnfinishedEntriesIfNeeded()
        return cachedEntries ?? []
    }

    @discardableResult
    func begin(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        trigger: RefreshHistoryTrigger,
        total: Int = 0
    ) -> UUID {
        recoverUnfinishedEntriesIfNeeded()
        var entries = cachedEntries ?? []
        guard entries.contains(where: { $0.id == id }) == false else {
            return id
        }

        entries.append(
            RefreshHistoryEntry(
                id: id,
                startedAt: startedAt,
                trigger: trigger,
                checkedPodcasts: [],
                status: .inProgress,
                completed: 0,
                total: max(0, total)
            )
        )
        cachedEntries = sorted(entries)
        persistImmediately()
        return id
    }

    func update(
        id: UUID,
        completed: Int? = nil,
        total: Int? = nil,
        podcast: RefreshHistoryPodcastCheck? = nil
    ) {
        recoverUnfinishedEntriesIfNeeded()
        guard var entries = cachedEntries,
              let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].status == .inProgress else { return }

        var entry = entries[index]
        if let completed {
            entry.completed = max(entry.completed, max(0, completed))
        }
        if let total {
            entry.total = max(entry.total, max(0, total))
        }
        if let podcast {
            if let podcastIndex = entry.checkedPodcasts.firstIndex(where: { $0.id == podcast.id }) {
                entry.checkedPodcasts[podcastIndex] = podcast
            } else {
                entry.checkedPodcasts.append(podcast)
            }
        }
        entries[index] = entry
        cachedEntries = sorted(entries)
        scheduleCoalescedPersistence()
        notifyDidChange()
    }

    func finish(
        id: UUID,
        status: RefreshHistoryStatus,
        finishedAt: Date = Date(),
        completed: Int? = nil,
        total: Int? = nil,
        checkedPodcasts: [RefreshHistoryPodcastCheck]? = nil,
        diagnostics: RefreshHistoryDiagnostics? = nil
    ) {
        recoverUnfinishedEntriesIfNeeded()
        guard var entries = cachedEntries,
              let index = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[index].status == .inProgress else { return }

        var entry = entries[index]
        entry.status = status
        entry.finishedAt = finishedAt
        if let completed { entry.completed = max(0, completed) }
        if let total { entry.total = max(0, total) }
        if let checkedPodcasts { entry.checkedPodcasts = checkedPodcasts }
        if let diagnostics { entry.diagnostics = diagnostics }
        entries[index] = entry
        cachedEntries = sorted(entries)
        persistImmediately()
    }

    func record(_ entry: RefreshHistoryEntry) {
        recoverUnfinishedEntriesIfNeeded()
        var entries = cachedEntries ?? []
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        cachedEntries = sorted(entries)
        persistImmediately()
    }

    func clear() {
        persistenceTask?.cancel()
        persistenceTask = nil
        persistencePending = false
        cachedEntries = []
        defaults.removeObject(forKey: Constants.defaultsKey)
        notifyDidChange()
    }

    /// Forces a pending coalesced write. This is also useful when a caller is
    /// about to leave a debug screen and wants the latest progress on disk.
    func flush() {
        persistenceTask?.cancel()
        persistenceTask = nil
        guard persistencePending else { return }
        persistencePending = false
        saveEntries(cachedEntries ?? [])
    }

    private func loadedEntries() -> [RefreshHistoryEntry] {
        guard let cachedEntries else {
            guard let data = defaults.data(forKey: Constants.defaultsKey) else {
                return []
            }

            return (try? decoder.decode([RefreshHistoryEntry].self, from: data)) ?? []
        }
        return cachedEntries
    }

    private func recoverUnfinishedEntriesIfNeeded() {
        guard cachedEntries == nil else { return }
        var entries = loadedEntries()
        let now = Date()
        var recovered = false
        for index in entries.indices where entries[index].status == .inProgress {
            entries[index].status = .interrupted
            entries[index].finishedAt = now
            recovered = true
        }
        cachedEntries = sorted(entries)
        if recovered {
            persistImmediately()
        }
    }

    private func sorted(_ entries: [RefreshHistoryEntry]) -> [RefreshHistoryEntry] {
        let sorted = entries.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            let lhsWasInterrupted = lhs.status == .interrupted
            let rhsWasInterrupted = rhs.status == .interrupted
            if lhsWasInterrupted != rhsWasInterrupted { return lhsWasInterrupted }
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
            return lhs.id.uuidString > rhs.id.uuidString
        }
        return Array(sorted.prefix(Constants.maximumEntries))
    }

    private func persistImmediately() {
        persistenceTask?.cancel()
        persistenceTask = nil
        persistencePending = false
        saveEntries(cachedEntries ?? [])
    }

    private func scheduleCoalescedPersistence() {
        persistencePending = true
        guard persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Constants.persistenceDelayNanoseconds)
            } catch {
                return
            }
            await self?.flush()
        }
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

    private var scheduledRefresh: PredictedReleaseRefreshSchedule?

    func schedule() -> PredictedReleaseRefreshSchedule? {
        scheduledRefresh
    }

    func record(_ schedule: PredictedReleaseRefreshSchedule) {
        scheduledRefresh = schedule
        notifyDidChange()
    }

    func clear() {
        scheduledRefresh = nil
        notifyDidChange()
    }

    private func notifyDidChange() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .predictedReleaseRefreshScheduleDidChange, object: nil)
        }
    }
}
#endif
