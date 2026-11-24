import Foundation
import SwiftData

extension Notification.Name {
    static let listeningHistoryDidChange = Notification.Name("listeningHistoryDidChange")
}

/// A Sendable copy of one canonical listening-history row.
///
/// Statistics deliberately consume this value rather than carrying SwiftData
/// models into a view task. The stable aggregation key is the same key used by
/// the store-split writer, so a session published twice or observed on two
/// devices is counted once.
struct ListeningStatisticsSessionValue: Hashable, Sendable {
    let id: String
    let feedURL: String
    let episodeID: String
    let podcastName: String?
    let episodeTitle: String?
    let sourceDeviceID: String
    let sourceDeviceName: String?
    let deviceModel: String?
    let startedAt: Date
    let endedAt: Date
    let startPosition: Double
    let endPosition: Double
    let listenedSeconds: Double
    let silenceGapTimeSavedSeconds: Double
    let playbackRateTimeSavedSeconds: Double
    let endedCleanly: Bool
    let isLegacyMigrated: Bool
    let updatedAt: Date

    init(
        id: String,
        feedURL: String,
        episodeID: String,
        podcastName: String? = nil,
        episodeTitle: String? = nil,
        sourceDeviceID: String,
        sourceDeviceName: String? = nil,
        deviceModel: String? = nil,
        startedAt: Date,
        endedAt: Date,
        startPosition: Double = 0,
        endPosition: Double = 0,
        listenedSeconds: Double,
        silenceGapTimeSavedSeconds: Double = 0,
        playbackRateTimeSavedSeconds: Double = 0,
        endedCleanly: Bool = false,
        isLegacyMigrated: Bool = false,
        updatedAt: Date = .distantPast
    ) {
        self.id = id
        self.feedURL = feedURL
        self.episodeID = episodeID
        self.podcastName = podcastName
        self.episodeTitle = episodeTitle
        self.sourceDeviceID = sourceDeviceID
        self.sourceDeviceName = sourceDeviceName
        self.deviceModel = deviceModel
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.startPosition = startPosition
        self.endPosition = endPosition
        self.listenedSeconds = listenedSeconds
        self.silenceGapTimeSavedSeconds = silenceGapTimeSavedSeconds
        self.playbackRateTimeSavedSeconds = playbackRateTimeSavedSeconds
        self.endedCleanly = endedCleanly
        self.isLegacyMigrated = isLegacyMigrated
        self.updatedAt = updatedAt
    }

    init(_ record: ListeningHistorySync) {
        self.init(
            id: record.id,
            feedURL: record.feedURL,
            episodeID: record.episodeID,
            podcastName: record.podcastName,
            episodeTitle: record.episodeTitle,
            sourceDeviceID: record.sourceDeviceID,
            sourceDeviceName: record.sourceDeviceName,
            deviceModel: record.deviceModel,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            startPosition: record.startPosition,
            endPosition: record.endPosition,
            listenedSeconds: record.listenedSeconds,
            silenceGapTimeSavedSeconds: record.silenceGapTimeSavedSeconds,
            playbackRateTimeSavedSeconds: record.playbackRateTimeSavedSeconds,
            endedCleanly: record.endedCleanly,
            isLegacyMigrated: record.isLegacyMigrated,
            updatedAt: record.updatedAt
        )
    }
}

struct ListeningStatisticsBaselineValue: Hashable, Sendable {
    let feedURL: String
    let podcastName: String?
    let totalSeconds: Double
    let silenceGapTimeSavedSeconds: Double
    let playbackRateTimeSavedSeconds: Double
    let capturedAt: Date

    init(_ baseline: ListeningBaselineSync) {
        self.feedURL = baseline.feedURL
        self.podcastName = baseline.podcastName
        self.totalSeconds = baseline.totalSeconds
        self.silenceGapTimeSavedSeconds = baseline.silenceGapTimeSavedSeconds
        self.playbackRateTimeSavedSeconds = baseline.playbackRateTimeSavedSeconds
        self.capturedAt = baseline.capturedAt
    }

    init(
        feedURL: String,
        podcastName: String? = nil,
        totalSeconds: Double,
        silenceGapTimeSavedSeconds: Double = 0,
        playbackRateTimeSavedSeconds: Double = 0,
        capturedAt: Date = .distantPast
    ) {
        self.feedURL = feedURL
        self.podcastName = podcastName
        self.totalSeconds = totalSeconds
        self.silenceGapTimeSavedSeconds = silenceGapTimeSavedSeconds
        self.playbackRateTimeSavedSeconds = playbackRateTimeSavedSeconds
        self.capturedAt = capturedAt
    }
}

struct ListeningStatisticsCompletionValue: Hashable, Sendable {
    let episodeIdentity: String
    let completedAt: Date
}

struct ListeningStatisticsQuery: Sendable {
    let period: PlaySessionSummaryPeriod
    let start: Date
    let end: Date
    let podcastFeedURL: String?
    let calendar: Calendar

    init(
        period: PlaySessionSummaryPeriod,
        start: Date,
        end: Date,
        podcastFeedURL: String? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.period = period
        self.start = start
        self.end = end
        self.podcastFeedURL = podcastFeedURL
        self.calendar = calendar
    }
}

struct ListeningStatisticsBucket: Identifiable, Equatable, Sendable {
    let start: Date
    let totalSeconds: Double

    var id: Date { start }
}

struct ListeningStatisticsPodcastRollup: Identifiable, Equatable, Sendable {
    let feedURL: String?
    let podcastName: String
    let totalSeconds: Double

    var id: String { feedURL ?? podcastName }
}

struct ListeningStatisticsPattern: Identifiable, Equatable, Sendable {
    let weekday: Int
    let hour: Int
    let totalSeconds: Double

    var id: String { "\(weekday)-\(hour)" }
}

struct ListeningStatisticsDeviceRollup: Identifiable, Equatable, Sendable {
    let deviceID: String
    let displayName: String
    let totalSeconds: Double
    let share: Double

    var id: String { deviceID }
}

struct ListeningStatisticsSnapshot: Equatable, Sendable {
    let period: PlaySessionSummaryPeriod
    let start: Date
    let end: Date
    let totalSeconds: Double
    let lifetimeTotalSeconds: Double
    let silenceGapTimeSavedSeconds: Double
    let playbackRateTimeSavedSeconds: Double
    let lifetimeSilenceGapTimeSavedSeconds: Double
    let lifetimePlaybackRateTimeSavedSeconds: Double
    let sessionCount: Int
    let completedEpisodeCount: Int?
    let buckets: [ListeningStatisticsBucket]
    let podcasts: [ListeningStatisticsPodcastRollup]
    let patterns: [ListeningStatisticsPattern]
    let devices: [ListeningStatisticsDeviceRollup]
    let sessions: [ListeningStatisticsSessionValue]
    /// True when the store has lifetime totals but cannot attribute them to a
    /// podcast or date range (the pre-split all-podcasts baseline).
    let hasUnattributedHistoricalData: Bool

    var hasListeningData: Bool { totalSeconds > 0 || lifetimeTotalSeconds > 0 }

    var accessibilitySummary: String {
        let time = totalSeconds >= 3_600
            ? "\(Int(totalSeconds / 3_600)) hours"
            : "\(Int(totalSeconds / 60)) minutes"
        let podcastSummary = podcasts.isEmpty
            ? "No podcast breakdown is available."
            : "Top podcast is \(podcasts[0].podcastName)."
        return "\(time) listened across \(sessionCount) recorded sessions. \(podcastSummary)"
    }
}

/// Pure aggregation for canonical history values.
///
/// Calendar intervals are local-calendar, start-inclusive/end-exclusive. A
/// session crossing midnight, a month boundary, or a DST transition is split
/// by its available timestamps. Its stored listening and saved-time values are
/// apportioned by wall-clock overlap; no missing historic attribution is
/// invented.
enum ListeningStatisticsAggregator {
    static func deduplicatedSessions(
        _ sessions: [ListeningStatisticsSessionValue],
        podcastFeedURL: String? = nil
    ) -> [ListeningStatisticsSessionValue] {
        var newestByIdentity: [String: ListeningStatisticsSessionValue] = [:]

        for session in sessions where isValid(session) && matches(session.feedURL, filter: podcastFeedURL) {
            let key = ListeningHistoryIdentity.canonicalAggregationKey(
                feedURL: session.feedURL,
                episodeID: session.episodeID,
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                listenedSeconds: session.listenedSeconds
            )
            if let existing = newestByIdentity[key], !prefers(session, over: existing) {
                continue
            }
            newestByIdentity[key] = session
        }

        return newestByIdentity.values.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id < $1.id
        }
    }

    static func snapshot(
        sessions: [ListeningStatisticsSessionValue],
        baselines: [ListeningStatisticsBaselineValue],
        completions: [ListeningStatisticsCompletionValue],
        completionDataAvailable: Bool,
        query: ListeningStatisticsQuery
    ) -> ListeningStatisticsSnapshot {
        let allSessions = deduplicatedSessions(sessions, podcastFeedURL: query.podcastFeedURL)
        let selectedSessions = allSessions.filter { session in
            query.period == .forever || overlaps(session, start: query.start, end: query.end)
        }

        let uniqueBaselines = uniqueBaselines(baselines, podcastFeedURL: query.podcastFeedURL)
        let hasBaseline = !uniqueBaselines.isEmpty
        let isAllTime = query.period == .forever
        let lifetimeSessions = hasBaseline
            ? allSessions.filter { !$0.isLegacyMigrated }
            : allSessions
        let liveSessions = isAllTime ? lifetimeSessions : selectedSessions

        var selectedTotal = 0.0
        var selectedSilenceSaved = 0.0
        var selectedPlaybackSaved = 0.0
        var buckets: [Date: Double] = [:]
        var podcastTotals: [String: (feed: String?, name: String, seconds: Double)] = [:]
        var patterns: [String: (weekday: Int, hour: Int, seconds: Double)] = [:]
        var deviceTotals: [String: (name: String, seconds: Double)] = [:]
        var contributingSessions: [ListeningStatisticsSessionValue] = []

        for session in liveSessions {
            let contribution = contribution(for: session, query: query)
            guard contribution.seconds > 0 else { continue }
            contributingSessions.append(session)
            selectedTotal += contribution.seconds
            selectedSilenceSaved += contribution.silenceSaved
            selectedPlaybackSaved += contribution.playbackSaved

            let podcastKey = session.feedURL.isEmpty ? (session.podcastName ?? "Unknown Podcast") : session.feedURL
            let podcastName = session.podcastName?.isEmpty == false ? session.podcastName! : "Unknown Podcast"
            podcastTotals[podcastKey, default: (session.feedURL.isEmpty ? nil : session.feedURL, podcastName, 0)].seconds += contribution.seconds

            let deviceName = session.sourceDeviceName?.isEmpty == false
                ? session.sourceDeviceName!
                : (session.deviceModel ?? "Unknown device")
            deviceTotals[session.sourceDeviceID, default: (deviceName, 0)].seconds += contribution.seconds

            addBucketsAndPatterns(
                for: session,
                query: query,
                buckets: &buckets,
                patterns: &patterns
            )
        }

        var lifetimeTotal = lifetimeSessions.reduce(0) { $0 + max(0, $1.listenedSeconds) }
        var lifetimeSilenceSaved = lifetimeSessions.reduce(0) { $0 + max(0, $1.silenceGapTimeSavedSeconds) }
        var lifetimePlaybackSaved = lifetimeSessions.reduce(0) { $0 + max(0, $1.playbackRateTimeSavedSeconds) }
        var hasUnattributedHistoricalData = false

        if isAllTime && hasBaseline {
            for baseline in uniqueBaselines {
                let seconds = max(0, baseline.totalSeconds)
                let silence = max(0, baseline.silenceGapTimeSavedSeconds)
                let playback = max(0, baseline.playbackRateTimeSavedSeconds)
                lifetimeTotal += seconds
                lifetimeSilenceSaved += silence
                lifetimePlaybackSaved += playback
                selectedTotal += seconds
                selectedSilenceSaved += silence
                selectedPlaybackSaved += playback

                if baseline.feedURL == ListeningBaselineSync.allPodcastsFeedURL {
                    hasUnattributedHistoricalData = true
                } else {
                    let key = baseline.feedURL
                    let name = baseline.podcastName?.isEmpty == false ? baseline.podcastName! : "Unknown Podcast"
                    podcastTotals[key, default: (baseline.feedURL, name, 0)].seconds += seconds
                }
                deviceTotals[ListeningDeviceIdentity.legacySharedID, default: ("Migrated history", 0)].seconds += seconds
            }
        }

        let completionCount: Int?
        if completionDataAvailable {
            let ids = completions.compactMap { completion -> String? in
                if query.period == .forever || (completion.completedAt >= query.start && completion.completedAt < query.end) {
                    return completion.episodeIdentity
                }
                return nil
            }
            completionCount = Set(ids).count
        } else {
            completionCount = nil
        }

        let totalForDeviceShares = deviceTotals.values.reduce(0) { $0 + $1.seconds }
        let devices = deviceTotals.map { deviceID, value in
            ListeningStatisticsDeviceRollup(
                deviceID: deviceID,
                displayName: value.name,
                totalSeconds: value.seconds,
                share: totalForDeviceShares > 0 ? value.seconds / totalForDeviceShares : 0
            )
        }
        .sorted { $0.totalSeconds > $1.totalSeconds }

        let normalizedBuckets = buckets.map { ListeningStatisticsBucket(start: $0.key, totalSeconds: $0.value) }
            .sorted { $0.start < $1.start }
        let normalizedPodcasts = podcastTotals.map { key, value in
            ListeningStatisticsPodcastRollup(
                feedURL: value.feed ?? (key.hasPrefix("http") ? key : nil),
                podcastName: value.name,
                totalSeconds: value.seconds
            )
        }
        .filter { $0.totalSeconds > 0 }
        .sorted {
            if $0.totalSeconds != $1.totalSeconds { return $0.totalSeconds > $1.totalSeconds }
            return $0.podcastName.localizedCaseInsensitiveCompare($1.podcastName) == .orderedAscending
        }

        return ListeningStatisticsSnapshot(
            period: query.period,
            start: query.start,
            end: query.end,
            totalSeconds: selectedTotal,
            lifetimeTotalSeconds: lifetimeTotal,
            silenceGapTimeSavedSeconds: selectedSilenceSaved,
            playbackRateTimeSavedSeconds: selectedPlaybackSaved,
            lifetimeSilenceGapTimeSavedSeconds: lifetimeSilenceSaved,
            lifetimePlaybackRateTimeSavedSeconds: lifetimePlaybackSaved,
            sessionCount: contributingSessions.count,
            completedEpisodeCount: completionCount,
            buckets: normalizedBuckets,
            podcasts: normalizedPodcasts,
            patterns: patterns.values
                .map { ListeningStatisticsPattern(weekday: $0.weekday, hour: $0.hour, totalSeconds: $0.seconds) }
                .sorted { $0.totalSeconds > $1.totalSeconds },
            devices: devices,
            sessions: contributingSessions.sorted { $0.startedAt > $1.startedAt },
            hasUnattributedHistoricalData: hasUnattributedHistoricalData
        )
    }

    private static func uniqueBaselines(
        _ baselines: [ListeningStatisticsBaselineValue],
        podcastFeedURL: String?
    ) -> [ListeningStatisticsBaselineValue] {
        let scoped = baselines.filter { matches($0.feedURL, filter: podcastFeedURL) }
        let perFeed = scoped.filter { $0.feedURL != ListeningBaselineSync.allPodcastsFeedURL }
        let candidates = perFeed.isEmpty ? scoped : perFeed
        var newestByFeed: [String: ListeningStatisticsBaselineValue] = [:]
        for baseline in candidates {
            if let existing = newestByFeed[baseline.feedURL], existing.capturedAt >= baseline.capturedAt {
                continue
            }
            newestByFeed[baseline.feedURL] = baseline
        }
        return Array(newestByFeed.values)
    }

    private struct Contribution {
        let seconds: Double
        let silenceSaved: Double
        let playbackSaved: Double
        let start: Date
        let end: Date
    }

    private static func contribution(
        for session: ListeningStatisticsSessionValue,
        query: ListeningStatisticsQuery
    ) -> Contribution {
        let start = max(session.startedAt, query.start)
        let end = min(session.endedAt, query.end)
        let wallDuration = session.endedAt.timeIntervalSince(session.startedAt)
        guard end > start, wallDuration > 0 else {
            return Contribution(seconds: 0, silenceSaved: 0, playbackSaved: 0, start: start, end: end)
        }
        let fraction = min(1, max(0, end.timeIntervalSince(start) / wallDuration))
        return Contribution(
            seconds: max(0, session.listenedSeconds) * fraction,
            silenceSaved: max(0, session.silenceGapTimeSavedSeconds) * fraction,
            playbackSaved: max(0, session.playbackRateTimeSavedSeconds) * fraction,
            start: start,
            end: end
        )
    }

    private static func addBucketsAndPatterns(
        for session: ListeningStatisticsSessionValue,
        query: ListeningStatisticsQuery,
        buckets: inout [Date: Double],
        patterns: inout [String: (weekday: Int, hour: Int, seconds: Double)]
    ) {
        let contribution = contribution(for: session, query: query)
        guard contribution.seconds > 0 else { return }
        let calendar = query.calendar
        var cursor = contribution.start
        while cursor < contribution.end {
            guard let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start else { break }
            guard let nextHour = calendar.date(byAdding: .hour, value: 1, to: hourStart) else { break }
            let blockEnd = min(nextHour, contribution.end)
            let blockFraction = blockEnd.timeIntervalSince(cursor) / max(contribution.end.timeIntervalSince(contribution.start), 0.001)
            let seconds = contribution.seconds * blockFraction

            let bucketStart: Date
            switch query.period {
            case .week, .month, .day:
                bucketStart = calendar.startOfDay(for: cursor)
            case .year:
                bucketStart = calendar.dateInterval(of: .month, for: cursor)?.start ?? calendar.startOfDay(for: cursor)
            case .forever:
                bucketStart = calendar.dateInterval(of: .year, for: cursor)?.start ?? calendar.startOfDay(for: cursor)
            }
            buckets[bucketStart, default: 0] += seconds

            let weekday = calendar.component(.weekday, from: cursor) - 1
            let hour = calendar.component(.hour, from: cursor)
            let key = "\(weekday)-\(hour)"
            patterns[key, default: (weekday, hour, 0)].seconds += seconds
            cursor = blockEnd
        }
    }

    private static func isValid(_ session: ListeningStatisticsSessionValue) -> Bool {
        session.startedAt.isFiniteDate
            && session.endedAt.isFiniteDate
            && session.endedAt > session.startedAt
            && session.listenedSeconds.isFinite
            && session.listenedSeconds > 0
    }

    private static func prefers(
        _ candidate: ListeningStatisticsSessionValue,
        over existing: ListeningStatisticsSessionValue
    ) -> Bool {
        if candidate.updatedAt != existing.updatedAt { return candidate.updatedAt > existing.updatedAt }
        if candidate.endedAt != existing.endedAt { return candidate.endedAt > existing.endedAt }
        if candidate.listenedSeconds != existing.listenedSeconds { return candidate.listenedSeconds > existing.listenedSeconds }
        return candidate.sourceDeviceID < existing.sourceDeviceID
    }

    private static func matches(_ value: String, filter: String?) -> Bool {
        guard let filter else { return true }
        if value == filter { return true }
        guard let valueURL = URL(string: value), let filterURL = URL(string: filter) else { return false }
        return valueURL.podcastFeedComparisonKeys.isDisjoint(with: filterURL.podcastFeedComparisonKeys) == false
    }

    private static func overlaps(_ session: ListeningStatisticsSessionValue, start: Date, end: Date) -> Bool {
        session.startedAt < end && session.endedAt > start
    }
}

/// Reads UserState off the main actor and keeps immutable values in memory for
/// the lifetime of a statistics screen. Period navigation therefore re-buckets
/// cached rows instead of rescanning SwiftData on every tap.
actor ListeningStatisticsAggregationActor {
    private let modelContainer: ModelContainer
    private var cachedSessions: [ListeningStatisticsSessionValue]?
    private var cachedBaselines: [ListeningStatisticsBaselineValue]?
    private var cachedCompletions: [ListeningStatisticsCompletionValue]?
    private var completionDataAvailable = false

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func invalidate() {
        cachedSessions = nil
        cachedBaselines = nil
        cachedCompletions = nil
        completionDataAvailable = false
    }

    func snapshot(query: ListeningStatisticsQuery) throws -> ListeningStatisticsSnapshot? {
        try loadIfNeeded()
        guard let cachedSessions, let cachedBaselines else { return nil }
        guard !cachedSessions.isEmpty || !cachedBaselines.isEmpty else { return nil }
        return ListeningStatisticsAggregator.snapshot(
            sessions: cachedSessions,
            baselines: cachedBaselines,
            completions: cachedCompletions ?? [],
            completionDataAvailable: completionDataAvailable,
            query: query
        )
    }

    private func loadIfNeeded() throws {
        guard cachedSessions == nil else { return }
        let context = ModelContext(modelContainer)
        cachedSessions = try context.fetch(FetchDescriptor<ListeningHistorySync>())
            .map(ListeningStatisticsSessionValue.init)
        cachedBaselines = try context.fetch(FetchDescriptor<ListeningBaselineSync>())
            .map(ListeningStatisticsBaselineValue.init)
        do {
            cachedCompletions = try context.fetch(FetchDescriptor<EpisodeStateSync>())
                .compactMap { state in
                    guard let completedAt = state.completedAt else { return nil }
                    return ListeningStatisticsCompletionValue(
                        episodeIdentity: state.id,
                        completedAt: completedAt
                    )
                }
            completionDataAvailable = true
        } catch {
            cachedCompletions = []
            completionDataAvailable = false
        }
    }
}

private extension Date {
    var isFiniteDate: Bool {
        self != .distantPast && self != .distantFuture && timeIntervalSinceReferenceDate.isFinite
    }
}
