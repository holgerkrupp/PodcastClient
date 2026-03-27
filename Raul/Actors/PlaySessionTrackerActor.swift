//
//  PlaySessionTrackerActor.swift
//  Raul
//
//  Created by Holger Krupp on 27.08.25.
//


import Foundation
import SwiftData
import UIKit

private struct SummaryPeriodKey: Hashable {
    let period: PlaySessionSummaryPeriod
    let periodStart: Date
}


@Model
final class RateSegment: Identifiable {
    // Properties made optional for CloudKit compatibility
    
    var id: UUID?
    var rate: Float?
    var startTime: Date?
    var startPosition: Double?
    var endTime: Date?
    var endPosition: Double?
    
    // Inverse relationship to parent PlaySession, required for SwiftData relationship syncing (e.g., for iCloud)
    var parentSession: PlaySession?

    init(
        id: UUID? = nil,
        rate: Float? = nil,
        startTime: Date? = nil,
        startPosition: Double? = nil,
        endTime: Date? = nil,
        endPosition: Double? = nil,
        parentSession: PlaySession? = nil
    ) {
        self.id = id
        self.rate = rate
        self.startTime = startTime
        self.startPosition = startPosition
        self.endTime = endTime
        self.endPosition = endPosition
        self.parentSession = parentSession
    }
}

@Model
final class PlaySession: Identifiable {
    // Properties made optional for CloudKit compatibility
    
    var id: UUID?
    
    // Use a relationship to the Episode model instead of just episodeID to enable SwiftData relationship syncing (e.g., for iCloud).
    // Explicit inverse relationship is required for proper syncing.
    @Relationship(inverse: \Episode.playSessions) var episode: Episode?
    var podcastName: String?
    var deviceModel: String?
    var osVersion: String?
    var appVersion: String?
    var startTime: Date?
    var endTime: Date?
    var startPosition: Double?
    var endPosition: Double?
    
    // Relationship to RateSegment with explicit inverse to RateSegment.parentSession for syncing
    @Relationship(deleteRule: .cascade, inverse: \RateSegment.parentSession) var segments: [RateSegment]?

    var endedCleanly: Bool?

    init(
        id: UUID? = nil,
        episode: Episode? = nil,
        deviceModel: String? = nil,
        osVersion: String? = nil,
        appVersion: String? = nil,
        startTime: Date? = nil,
        endTime: Date? = nil,
        startPosition: Double? = nil,
        endPosition: Double? = nil,
        segments: [RateSegment]? = [],
        endedCleanly: Bool? = nil
    ) {
        self.id = id
        self.episode = episode
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.startTime = startTime
        self.endTime = endTime
        self.startPosition = startPosition
        self.endPosition = endPosition
        self.segments = segments
        self.endedCleanly = endedCleanly
        self.podcastName = episode?.podcast?.title
    }
}

@ModelActor
actor PlaySessionTrackerActor {
    private let rawSessionRetentionDays = 30
    private var currentSession: PlaySession?

    private func fetchEpisode(url episodeURL: URL) -> Episode? {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { $0.url == episodeURL }
        )
        return try? modelContext.fetch(descriptor).first
    }

    /// Call this after initialization to kick off recovery.
    func startRecovery()  {
        Task {
            recoverIncompleteSessionIfNeeded()
            backfillListeningStatsIfNeeded()
            backfillSummariesIfNeeded()
            pruneOldSessionsIfNeeded()
        }
    }

    func startOrUpdateSession(episodeURL: URL, position: Double, rate: Float, appVersion: String) async {
        guard let episode = fetchEpisode(url: episodeURL) else { return }

        let now = Date()
        let deviceModel = getDeviceModel()
        let osVersion = getOSVersion()

        if let session = currentSession, session.episode?.url == episodeURL {
            // Continue existing session; maybe add new rate segment if rate changed
            if let lastSegment = session.segments?.last, lastSegment.rate != rate {
                endCurrentRateSegment(at: now, position: position)
                addRateSegment(rate: rate, startTime: now, startPosition: position)
            }
            return
        }

        // End previous session if different episode
        if (currentSession != nil) {
            endSession(at: position, appTerminated: false)
        }

        // Start new session
        let id = UUID()
        currentSession = PlaySession(
            id: id,
            episode: episode,
            deviceModel: deviceModel,
            osVersion: osVersion,
            appVersion: appVersion,
            startTime: now,
            endTime: nil,
            startPosition: position,
            endPosition: nil,
            segments: [RateSegment(rate: rate, startTime: now, startPosition: position)],
            endedCleanly: false
        )
         saveSession()
    }

    func pauseSession(at position: Double) async {
        endSession(at: position, appTerminated: false)
    }

    func handlePlaybackRateChange(to rate: Float, at position: Double) async {
        let now = Date()
        guard let session = currentSession else { return }
        if let lastSegment = session.segments?.last, lastSegment.rate != rate {
            endCurrentRateSegment(at: now, position: position)
            addRateSegment(rate: rate, startTime: now, startPosition: position)
             saveSession()
        }
    }

    func updatePosition(_ position: Double) async {
        // For periodic progress update; updates can be batched or rate limited as needed
        // Optionally flush to disk here
    }

    private func endSession(at position: Double, appTerminated: Bool) {
        guard let session = currentSession else { return }
        let now = Date()
        session.endTime = now
        session.endPosition = position
        session.endedCleanly = !appTerminated
        endCurrentRateSegment(at: now, position: position)
        currentSession = nil

        let touchedHours = recordListeningStats(for: session)
        rebuildSummaries(forHourStarts: touchedHours, podcastFeed: session.episode?.podcast?.feed, podcastName: session.podcastName)
        pruneOldSessionsIfNeeded()
        saveSession()
    }

    private func endCurrentRateSegment(at date: Date, position: Double) {
        guard let session = currentSession, let last = session.segments?.last else { return }
        last.endTime = date
        last.endPosition = position
        if var segments = session.segments {
            segments[segments.count - 1] = last
            session.segments = segments
        }
        currentSession = session
    }

    private func addRateSegment(rate: Float, startTime: Date, startPosition: Double) {
        guard let session = currentSession else { return }
        let segment = RateSegment(rate: rate, startTime: startTime, startPosition: startPosition)
        if session.segments == nil {
            session.segments = []
        }
        session.segments?.append(segment)
        currentSession = session
    }

    @discardableResult
    private func recordListeningStats(for session: PlaySession) -> [Date] {
        guard let start = session.startTime, let end = session.endTime, end > start else { return [] }

        let podcastFeed = session.episode?.podcast?.feed
        let podcastName = session.podcastName
        let calendar = Calendar.current

        var buckets: [Date: Double] = [:]
        var cursor = start
        while cursor < end {
            let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start ?? cursor
            let nextHour = calendar.date(byAdding: .hour, value: 1, to: hourStart) ?? end
            let blockEnd = min(nextHour, end)
            let seconds = blockEnd.timeIntervalSince(cursor)
            buckets[hourStart, default: 0] += seconds
            cursor = blockEnd
        }

        guard let firstHour = buckets.keys.min() else { return [] }
        let lastHour = buckets.keys.max() ?? firstHour
        let endLimit = calendar.date(byAdding: .hour, value: 1, to: lastHour) ?? end

        let predicate: Predicate<ListeningStat>?
        if let podcastFeed {
            predicate = #Predicate<ListeningStat> { stat in
                stat.startOfHour != nil
                && stat.startOfHour! >= firstHour
                && stat.startOfHour! < endLimit
                && stat.podcastFeed == podcastFeed
            }
        } else {
            predicate = #Predicate<ListeningStat> { stat in
                stat.startOfHour != nil
                && stat.startOfHour! >= firstHour
                && stat.startOfHour! < endLimit
            }
        }

        let descriptor = FetchDescriptor<ListeningStat>(predicate: predicate)
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        var existingByHour: [Date: ListeningStat] = [:]
        for stat in existing {
            if let startOfHour = stat.startOfHour {
                existingByHour[startOfHour] = stat
            }
        }

        for (hourStart, seconds) in buckets {
            if let stat = existingByHour[hourStart] {
                stat.totalSeconds = (stat.totalSeconds ?? 0) + seconds
                if stat.podcastName == nil { stat.podcastName = podcastName }
            } else {
                let stat = ListeningStat(
                    id: UUID(),
                    startOfHour: hourStart,
                    podcastFeed: podcastFeed,
                    podcastName: podcastName,
                    totalSeconds: seconds
                )
                modelContext.insert(stat)
            }
        }
        return Array(buckets.keys)
    }

    private func rebuildSummaries(forHourStarts hourStarts: [Date], podcastFeed: URL?, podcastName: String?) {
        guard !hourStarts.isEmpty else { return }

        let periods = Set(hourStarts.flatMap { hourStart in
            PlaySessionSummaryPeriod.allCases.map { period in
                SummaryPeriodKey(period: period, periodStart: summaryPeriodStart(for: period, containing: hourStart))
            }
        })

        for period in periods {
            rebuildSummary(period: period.period, periodStart: period.periodStart, podcastFeed: podcastFeed, podcastName: podcastName)
        }
    }

    private func rebuildSummary(
        period: PlaySessionSummaryPeriod,
        periodStart: Date,
        podcastFeed: URL?,
        podcastName: String?
    ) {
        let interval = summaryInterval(for: period, periodStart: periodStart)
        let periodKind = period.rawValue

        let statPredicate: Predicate<ListeningStat>
        if let podcastFeed {
            statPredicate = #Predicate<ListeningStat> { stat in
                stat.startOfHour != nil
                && stat.startOfHour! >= interval.start
                && stat.startOfHour! < interval.end
                && stat.podcastFeed == podcastFeed
            }
        } else {
            statPredicate = #Predicate<ListeningStat> { stat in
                stat.startOfHour != nil
                && stat.startOfHour! >= interval.start
                && stat.startOfHour! < interval.end
                && stat.podcastFeed == nil
            }
        }

        let stats = (try? modelContext.fetch(FetchDescriptor<ListeningStat>(predicate: statPredicate))) ?? []
        let totalSeconds = stats.reduce(0.0) { $0 + ($1.totalSeconds ?? 0) }
        let activeHourCount = stats.filter { ($0.totalSeconds ?? 0) > 0 }.count

        let summaryPredicate: Predicate<PlaySessionSummary>
        if let podcastFeed {
            summaryPredicate = #Predicate<PlaySessionSummary> { summary in
                summary.periodKind == periodKind
                && summary.periodStart == periodStart
                && summary.podcastFeed == podcastFeed
            }
        } else {
            summaryPredicate = #Predicate<PlaySessionSummary> { summary in
                summary.periodKind == periodKind
                && summary.periodStart == periodStart
                && summary.podcastFeed == nil
            }
        }

        let existing = try? modelContext.fetch(FetchDescriptor<PlaySessionSummary>(predicate: summaryPredicate)).first

        if totalSeconds > 0 {
            let summary = existing ?? PlaySessionSummary(
                id: UUID(),
                periodKind: period.rawValue,
                periodStart: periodStart,
                podcastFeed: podcastFeed,
                podcastName: podcastName,
                totalSeconds: totalSeconds,
                activeHourCount: activeHourCount
            )
            summary.periodKind = period.rawValue
            summary.periodStart = periodStart
            summary.podcastFeed = podcastFeed
            summary.podcastName = podcastName ?? summary.podcastName
            summary.totalSeconds = totalSeconds
            summary.activeHourCount = activeHourCount
            if existing == nil {
                modelContext.insert(summary)
            }
        } else if let existing {
            modelContext.delete(existing)
        }
    }

    private func backfillListeningStatsIfNeeded() {
        let existing = (try? modelContext.fetch(FetchDescriptor<ListeningStat>())) ?? []
        if !existing.isEmpty { return }

        let allSessions = (try? modelContext.fetch(FetchDescriptor<PlaySession>())) ?? []
        for session in allSessions {
            recordListeningStats(for: session)
        }
        modelContext.saveIfNeeded()
    }

    private func backfillSummariesIfNeeded() {
        let existing = (try? modelContext.fetch(FetchDescriptor<PlaySessionSummary>())) ?? []
        if !existing.isEmpty { return }
        rebuildSummariesFromListeningStats()
    }

    func rebuildListeningStats() {
        let existing = (try? modelContext.fetch(FetchDescriptor<ListeningStat>())) ?? []
        for stat in existing {
            modelContext.delete(stat)
        }

        let allSessions = (try? modelContext.fetch(FetchDescriptor<PlaySession>())) ?? []
        for session in allSessions {
            recordListeningStats(for: session)
        }
        rebuildSummariesFromListeningStats()
        modelContext.saveIfNeeded()
    }

    private func rebuildSummariesFromListeningStats() {
        let existing = (try? modelContext.fetch(FetchDescriptor<PlaySessionSummary>())) ?? []
        for summary in existing {
            modelContext.delete(summary)
        }

        let allStats = (try? modelContext.fetch(FetchDescriptor<ListeningStat>())) ?? []
        let groupedStats = Dictionary(grouping: allStats) { $0.podcastFeed }

        for (podcastFeed, stats) in groupedStats {
            let podcastName = stats.first(where: { ($0.podcastName?.isEmpty == false) })?.podcastName
            let hourStarts = stats.compactMap(\.startOfHour)
            let periods = Set(hourStarts.flatMap { hourStart in
                PlaySessionSummaryPeriod.allCases.map { period in
                    SummaryPeriodKey(period: period, periodStart: summaryPeriodStart(for: period, containing: hourStart))
                }
            })

            for period in periods {
                rebuildSummary(period: period.period, periodStart: period.periodStart, podcastFeed: podcastFeed, podcastName: podcastName)
            }
        }
    }

    // Recovery logic: On launch, check if a session was left open, and finalize it
    private func recoverIncompleteSessionIfNeeded()  {
        // Fetch all incomplete sessions (where endTime == nil)
        let descriptor = FetchDescriptor<PlaySession>(predicate: #Predicate { $0.endTime == nil })
        guard let incompleteSessions = try? modelContext.fetch(descriptor), !incompleteSessions.isEmpty else { return }
        
        for session in incompleteSessions {
            guard let episode = session.episode, let sessionStart = session.startTime, let sessionStartPosition = session.startPosition else { continue }
            // Find all sessions for this episode with startTime > this session
            let allSessions = (try? modelContext.fetch(FetchDescriptor<PlaySession>())) ?? []
            let newerSessions = allSessions
                .filter { $0.episode?.url == episode.url && $0.startTime != nil && ($0.startTime! > sessionStart) }
            // Find the earliest newer session
            let nextSession = newerSessions.sorted(by: { ($0.startTime ?? .distantFuture) < ($1.startTime ?? .distantFuture) }).first
            var endPosition: Double?
            if let next = nextSession, let nextStartPosition = next.startPosition {
                // Use the next session's startPosition
                endPosition = nextStartPosition
            } else {
                // Use the episode's maxPlayProgress (convert to absolute position, not ratio)
                let maxProgress = episode.maxPlayProgress
                endPosition = (episode.duration ?? 0.0) * maxProgress
            }
            // Prevent overlap: ensure endPosition > startPosition and <= nextSession.startPosition (if any)
            if let endPosition, endPosition > sessionStartPosition {
                session.endPosition = endPosition
                session.endedCleanly = false
                // Update last segment too
                if var segments = session.segments, !segments.isEmpty {
                    let last = segments[segments.count - 1]
                    last.endPosition = endPosition
                    // Estimate endTime using playback rate
                    let rate = last.rate ?? 1.0
                    let duration = endPosition - (last.startPosition ?? sessionStartPosition)
                    if let segStartTime = last.startTime {
                        last.endTime = segStartTime.addingTimeInterval(duration / Double(rate))
                        session.endTime = last.endTime
                    }
                    segments[segments.count - 1] = last
                    session.segments = segments
                } else {
                    // If no segment, just set endTime
                    if let start = session.startTime {
                        let rate = session.segments?.last?.rate ?? 1.0
                        let duration = endPosition - sessionStartPosition
                        session.endTime = start.addingTimeInterval(duration / Double(rate))
                    }
                }
                let touchedHours = recordListeningStats(for: session)
                rebuildSummaries(forHourStarts: touchedHours, podcastFeed: episode.podcast?.feed, podcastName: session.podcastName)
                // Save the session
                modelContext.saveIfNeeded()
            }
        }
    }

    private func pruneOldSessionsIfNeeded() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -rawSessionRetentionDays, to: Date()) else { return }
        let descriptor = FetchDescriptor<PlaySession>(
            predicate: #Predicate<PlaySession> {
                $0.endTime != nil && $0.endTime! < cutoff
            }
        )

        let oldSessions = (try? modelContext.fetch(descriptor)) ?? []
        for session in oldSessions {
            if let segments = session.segments {
                for segment in segments {
                    modelContext.delete(segment)
                }
            }
            modelContext.delete(session)
        }
    }

    private func summaryPeriodStart(for period: PlaySessionSummaryPeriod, containing date: Date) -> Date {
        let calendar = Calendar.current
        switch period {
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return calendar.date(from: components) ?? calendar.startOfDay(for: date)
        case .month:
            let components = calendar.dateComponents([.year, .month], from: date)
            return calendar.date(from: components) ?? calendar.startOfDay(for: date)
        case .year:
            let components = calendar.dateComponents([.year], from: date)
            return calendar.date(from: components) ?? calendar.startOfDay(for: date)
        }
    }

    private func summaryInterval(for period: PlaySessionSummaryPeriod, periodStart: Date) -> DateInterval {
        let calendar = Calendar.current
        let end: Date
        switch period {
        case .day:
            end = calendar.date(byAdding: .day, value: 1, to: periodStart) ?? periodStart
        case .week:
            end = calendar.date(byAdding: .day, value: 7, to: periodStart) ?? periodStart
        case .month:
            end = calendar.date(byAdding: .month, value: 1, to: periodStart) ?? periodStart
        case .year:
            end = calendar.date(byAdding: .year, value: 1, to: periodStart) ?? periodStart
        }
        return DateInterval(start: periodStart, end: end)
    }



    private func saveSession() {
        modelContext.saveIfNeeded()
    }

    // MARK: - Device Info Helpers

    private func getDeviceModel() -> String {
#if os(iOS)
   
        return UIDevice.current.model
#elseif os(macOS)
        return "Mac"
#else
        return "Unknown"
#endif
    }

    private func getOSVersion() -> String {
#if os(iOS)
    
        return UIDevice.current.systemVersion
#elseif os(macOS)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
#else
        return "Unknown"
#endif
    }
}
