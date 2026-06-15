//
//  PlaySessionTrackerActor.swift
//  Raul
//
//  Created by Holger Krupp on 27.08.25.
//


import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

private struct SummaryPeriodKey: Hashable {
    let period: PlaySessionSummaryPeriod
    let periodStart: Date
}

private struct PlaySessionSummarySnapshot {
    let period: PlaySessionSummaryPeriod
    let periodStart: Date
    let podcastFeed: URL?
    let podcastName: String?
    let totalSeconds: Double
    let silenceGapTimeSavedSeconds: Double
    let playbackRateTimeSavedSeconds: Double
    let activeHourCount: Int
}

private struct SummaryAggregationKey: Hashable {
    let period: PlaySessionSummaryPeriod
    let periodStart: Date
    let podcastFeed: URL?
}

private struct SummaryAggregation {
    let period: PlaySessionSummaryPeriod
    let periodStart: Date
    let podcastFeed: URL?
    let podcastName: String?
    let totalSeconds: Double
    let silenceGapTimeSavedSeconds: Double
    let playbackRateTimeSavedSeconds: Double
    let activeHourCount: Int
}

private struct SummaryAggregationValue {
    var podcastName: String? = nil
    var totalSeconds: Double = 0
    var silenceGapTimeSavedSeconds: Double = 0
    var playbackRateTimeSavedSeconds: Double = 0
    var activeHourCount: Int = 0
}

private struct PlaybackRateStatKey: Hashable {
    let startOfHour: Date
    let podcastFeed: URL?
}

enum PlaybackRateSavingsCalculator {
    static func secondsSaved(in session: PlaySession) -> TimeInterval {
        guard
            let sessionStart = session.startTime,
            let sessionEnd = session.endTime,
            sessionEnd > sessionStart
        else {
            return 0
        }

        let segments = (session.segments ?? [])
            .compactMap { segment -> (segment: RateSegment, start: Date)? in
                guard let start = segment.startTime else { return nil }
                return (segment, start)
            }
            .sorted { $0.start < $1.start }

        return segments.enumerated().reduce(0) { total, entry in
            let index = entry.offset
            let segment = entry.element.segment
            let start = max(entry.element.start, sessionStart)
            let nextStart = index + 1 < segments.count ? segments[index + 1].start : sessionEnd
            let explicitEnd = segment.endTime ?? sessionEnd
            let end = min(sessionEnd, nextStart, explicitEnd)
            guard end > start else { return total }

            let rate = max(Double(segment.rate ?? 1), 0)
            guard rate > 1 else { return total }
            return total + end.timeIntervalSince(start) * (rate - 1)
        }
    }
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
    var sourceDeviceID: String?
    var sourceDeviceName: String?
    var deviceModel: String?
    var osVersion: String?
    var appVersion: String?
    var startTime: Date?
    var endTime: Date?
    var startPosition: Double?
    var endPosition: Double?
    var silenceGapTimeSavedSeconds: Double?
    
    // Relationship to RateSegment with explicit inverse to RateSegment.parentSession for syncing
    @Relationship(deleteRule: .cascade, inverse: \RateSegment.parentSession) var segments: [RateSegment]?

    var endedCleanly: Bool?

    init(
        id: UUID? = nil,
        episode: Episode? = nil,
        sourceDeviceID: String? = nil,
        sourceDeviceName: String? = nil,
        deviceModel: String? = nil,
        osVersion: String? = nil,
        appVersion: String? = nil,
        startTime: Date? = nil,
        endTime: Date? = nil,
        startPosition: Double? = nil,
        endPosition: Double? = nil,
        silenceGapTimeSavedSeconds: Double? = 0,
        segments: [RateSegment]? = [],
        endedCleanly: Bool? = nil
    ) {
        self.id = id
        self.episode = episode
        self.sourceDeviceID = sourceDeviceID
        self.sourceDeviceName = sourceDeviceName
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.startTime = startTime
        self.endTime = endTime
        self.startPosition = startPosition
        self.endPosition = endPosition
        self.silenceGapTimeSavedSeconds = silenceGapTimeSavedSeconds
        self.segments = segments
        self.endedCleanly = endedCleanly
        self.podcastName = episode?.displayPodcastTitle
    }
}

@ModelActor
actor PlaySessionTrackerActor {
    private let rawSessionRetentionDays = 30
    private let analyticsBatchSize = 500
    private let playbackRateSavingsRepairKey = "playbackRateSavingsRepairVersion"
    private let playbackRateSavingsRepairVersion = 2
    private var currentSession: PlaySession?

    private func fetchEpisode(url episodeURL: URL) -> Episode? {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { $0.url == episodeURL }
        )
        return try? modelContext.fetch(descriptor).first
    }

    /// Call this after initialization to kick off recovery.
    func startRecovery() async {
        recoverIncompleteSessionIfNeeded()
        backfillListeningStatsIfNeeded()
        backfillSummariesIfNeeded()
        pruneOldSessionsIfNeeded()
        modelContext.saveIfNeeded()
    }

    func startOrUpdateSession(episodeURL: URL, position: Double, rate: Float, appVersion: String) async {
        guard let episode = fetchEpisode(url: episodeURL) else { return }

        let now = Date()
        let deviceModel = await getDeviceModel()
        let osVersion = await getOSVersion()
        let deviceIdentity = ListeningDeviceIdentity.current()

        if let session = currentSession, session.episode?.url == episodeURL {
            // Continue existing session; maybe add new rate segment if rate changed
            if let activeSegment = activeRateSegment(in: session), activeSegment.rate != rate {
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
            sourceDeviceID: deviceIdentity.id,
            sourceDeviceName: deviceIdentity.displayName,
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
        if let activeSegment = activeRateSegment(in: session), activeSegment.rate != rate {
            endCurrentRateSegment(at: now, position: position)
            addRateSegment(rate: rate, startTime: now, startPosition: position)
             saveSession()
        }
    }

    func updatePosition(_ position: Double) async {
        // For periodic progress update; updates can be batched or rate limited as needed
        // Optionally flush to disk here
    }

    func recordSilenceGapTimeSaved(_ seconds: TimeInterval) async {
        guard seconds.isFinite, seconds > 0, let session = currentSession else { return }
        session.silenceGapTimeSavedSeconds = (session.silenceGapTimeSavedSeconds ?? 0) + seconds
        currentSession = session
        modelContext.saveIfNeeded()
    }

    private func endSession(at position: Double, appTerminated: Bool) {
        guard let session = currentSession else { return }
        let now = Date()
        session.endTime = now
        session.endPosition = position
        session.endedCleanly = !appTerminated
        endCurrentRateSegment(at: now, position: position)
        currentSession = nil

        recordSilenceGapTimeSavedForEpisode(session)
        let touchedHours = recordListeningStats(for: session)
        rebuildSummaries(forHourStarts: touchedHours, podcastFeed: session.episode?.podcast?.feed, podcastName: session.podcastName)
        pruneOldSessionsIfNeeded()
        saveSession()
    }

    private func recordSilenceGapTimeSavedForEpisode(_ session: PlaySession) {
        guard
            let savedSeconds = session.silenceGapTimeSavedSeconds,
            savedSeconds.isFinite,
            savedSeconds > 0,
            let metadata = session.episode?.metaData
        else {
            return
        }

        if metadata.silenceGapTimeSavedDurations == nil {
            metadata.silenceGapTimeSavedDurations = CodableArray([])
        }
        metadata.silenceGapTimeSavedDurations?.elements.append(savedSeconds)
        metadata.totalSilenceGapTimeSaved += savedSeconds
    }

    private func playbackRateTimeSaved(for session: PlaySession) -> TimeInterval {
        PlaybackRateSavingsCalculator.secondsSaved(in: session)
    }

    private func activeRateSegment(in session: PlaySession) -> RateSegment? {
        let segments = session.segments ?? []
        return segments
            .filter { $0.endTime == nil }
            .max { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
            ?? segments.max { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
    }

    private func endCurrentRateSegment(at date: Date, position: Double) {
        guard let session = currentSession, let activeSegment = activeRateSegment(in: session) else { return }
        activeSegment.endTime = date
        activeSegment.endPosition = position
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
        let sessionDuration = end.timeIntervalSince(start)
        let savedSecondsTotal = max(0, session.silenceGapTimeSavedSeconds ?? 0)
        let playbackRateSavedSecondsTotal = playbackRateTimeSaved(for: session)
        let calendar = Calendar.current

        var buckets: [Date: Double] = [:]
        var savedBuckets: [Date: Double] = [:]
        var playbackRateSavedBuckets: [Date: Double] = [:]
        var cursor = start
        while cursor < end {
            let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start ?? cursor
            let nextHour = calendar.date(byAdding: .hour, value: 1, to: hourStart) ?? end
            let blockEnd = min(nextHour, end)
            let seconds = blockEnd.timeIntervalSince(cursor)
            buckets[hourStart, default: 0] += seconds
            if savedSecondsTotal > 0, sessionDuration > 0 {
                savedBuckets[hourStart, default: 0] += savedSecondsTotal * (seconds / sessionDuration)
            }
            if playbackRateSavedSecondsTotal > 0, sessionDuration > 0 {
                playbackRateSavedBuckets[hourStart, default: 0] += playbackRateSavedSecondsTotal * (seconds / sessionDuration)
            }
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
            let savedSeconds = savedBuckets[hourStart] ?? 0
            let playbackRateSavedSeconds = playbackRateSavedBuckets[hourStart] ?? 0
            if let stat = existingByHour[hourStart] {
                stat.totalSeconds = (stat.totalSeconds ?? 0) + seconds
                stat.silenceGapTimeSavedSeconds = (stat.silenceGapTimeSavedSeconds ?? 0) + savedSeconds
                stat.playbackRateTimeSavedSeconds = (stat.playbackRateTimeSavedSeconds ?? 0) + playbackRateSavedSeconds
                if stat.podcastName == nil { stat.podcastName = podcastName }
            } else {
                let stat = ListeningStat(
                    id: UUID(),
                    startOfHour: hourStart,
                    podcastFeed: podcastFeed,
                    podcastName: podcastName,
                    totalSeconds: seconds,
                    silenceGapTimeSavedSeconds: savedSeconds,
                    playbackRateTimeSavedSeconds: playbackRateSavedSeconds
                )
                modelContext.insert(stat)
            }
        }
        return Array(buckets.keys)
    }

    private func rebuildSummaries(forHourStarts hourStarts: [Date], podcastFeed: URL?, podcastName: String?) {
        guard !hourStarts.isEmpty else { return }

        let periods = Set(hourStarts.flatMap { hourStart in
            PlaySessionSummaryPeriod.allCases.filter { $0 != .forever }.map { period in
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
        let silenceGapTimeSavedSeconds = stats.reduce(0.0) { $0 + ($1.silenceGapTimeSavedSeconds ?? 0) }
        let playbackRateTimeSavedSeconds = stats.reduce(0.0) { $0 + ($1.playbackRateTimeSavedSeconds ?? 0) }
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
                silenceGapTimeSavedSeconds: silenceGapTimeSavedSeconds,
                playbackRateTimeSavedSeconds: playbackRateTimeSavedSeconds,
                activeHourCount: activeHourCount
            )
            summary.periodKind = period.rawValue
            summary.periodStart = periodStart
            summary.podcastFeed = podcastFeed
            summary.podcastName = podcastName ?? summary.podcastName
            summary.totalSeconds = totalSeconds
            summary.silenceGapTimeSavedSeconds = silenceGapTimeSavedSeconds
            summary.playbackRateTimeSavedSeconds = playbackRateTimeSavedSeconds
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

    private func repairPlaybackRateSavingsIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: playbackRateSavingsRepairKey) < playbackRateSavingsRepairVersion else {
            return
        }

        let stats = (try? modelContext.fetch(FetchDescriptor<ListeningStat>())) ?? []
        var statsByKey: [PlaybackRateStatKey: ListeningStat] = [:]
        for stat in stats {
            stat.playbackRateTimeSavedSeconds = 0
            if let startOfHour = stat.startOfHour {
                statsByKey[PlaybackRateStatKey(startOfHour: startOfHour, podcastFeed: stat.podcastFeed)] = stat
            }
        }

        let sessions = (try? modelContext.fetch(FetchDescriptor<PlaySession>())) ?? []
        let calendar = Calendar.current
        for session in sessions {
            guard
                let start = session.startTime,
                let end = session.endTime,
                end > start
            else {
                continue
            }

            let savedSeconds = playbackRateTimeSaved(for: session)
            let sessionDuration = end.timeIntervalSince(start)
            guard savedSeconds > 0, sessionDuration > 0 else { continue }

            var cursor = start
            while cursor < end {
                let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start ?? cursor
                let nextHour = calendar.date(byAdding: .hour, value: 1, to: hourStart) ?? end
                let blockEnd = min(nextHour, end)
                let blockDuration = blockEnd.timeIntervalSince(cursor)
                let key = PlaybackRateStatKey(
                    startOfHour: hourStart,
                    podcastFeed: session.episode?.podcast?.feed
                )
                if let stat = statsByKey[key] {
                    stat.playbackRateTimeSavedSeconds =
                        (stat.playbackRateTimeSavedSeconds ?? 0)
                        + savedSeconds * (blockDuration / sessionDuration)
                }
                cursor = blockEnd
            }
        }

        rebuildSummariesFromListeningStats()
        modelContext.saveIfNeeded()
        defaults.set(playbackRateSavingsRepairVersion, forKey: playbackRateSavingsRepairKey)
    }

    func rebuildListeningStats() {
        let preservedSummaries = playSessionSummarySnapshots()

        backfillMissingListeningStatsFromRawSessions()
        rebuildSummariesFromListeningStats(preservedSummaries: preservedSummaries)
        modelContext.saveIfNeeded()
        repairPlaybackRateSavingsIfNeeded()
    }

    private func playSessionSummarySnapshots() -> [PlaySessionSummarySnapshot] {
        var snapshots: [PlaySessionSummarySnapshot] = []
        var offset = 0

        while true {
            var descriptor = FetchDescriptor<PlaySessionSummary>(
                sortBy: [SortDescriptor(\.periodStart, order: .forward)]
            )
            descriptor.fetchLimit = analyticsBatchSize
            descriptor.fetchOffset = offset

            let summaries = (try? modelContext.fetch(descriptor)) ?? []
            if summaries.isEmpty { break }

            snapshots.append(contentsOf: summaries.compactMap { summary in
                guard
                    let periodKind = summary.periodKind,
                    let period = PlaySessionSummaryPeriod(rawValue: periodKind),
                    let periodStart = summary.periodStart,
                    let totalSeconds = summary.totalSeconds,
                    totalSeconds > 0
                else {
                    return nil
                }
                return PlaySessionSummarySnapshot(
                    period: period,
                    periodStart: periodStart,
                    podcastFeed: summary.podcastFeed,
                    podcastName: summary.podcastName,
                    totalSeconds: totalSeconds,
                    silenceGapTimeSavedSeconds: summary.silenceGapTimeSavedSeconds ?? 0,
                    playbackRateTimeSavedSeconds: summary.playbackRateTimeSavedSeconds ?? 0,
                    activeHourCount: summary.activeHourCount ?? 0
                )
            })

            if summaries.count < analyticsBatchSize { break }
            offset += analyticsBatchSize
        }

        return snapshots
    }

    private func backfillMissingListeningStatsFromRawSessions() {
        var offset = 0

        while true {
            var descriptor = FetchDescriptor<PlaySession>(
                sortBy: [SortDescriptor(\.startTime, order: .forward)]
            )
            descriptor.fetchLimit = analyticsBatchSize
            descriptor.fetchOffset = offset

            let sessions = (try? modelContext.fetch(descriptor)) ?? []
            if sessions.isEmpty { break }

            for session in sessions {
                recordMissingListeningStats(for: session)
            }

            modelContext.saveIfNeeded()
            if sessions.count < analyticsBatchSize { break }
            offset += analyticsBatchSize
        }
    }

    private func recordMissingListeningStats(for session: PlaySession) {
        guard let start = session.startTime, let end = session.endTime, end > start else { return }

        let podcastFeed = session.episode?.podcast?.feed
        let podcastName = session.podcastName
        let sessionDuration = end.timeIntervalSince(start)
        let savedSecondsTotal = max(0, session.silenceGapTimeSavedSeconds ?? 0)
        let playbackRateSavedSecondsTotal = playbackRateTimeSaved(for: session)
        let calendar = Calendar.current

        var buckets: [Date: Double] = [:]
        var savedBuckets: [Date: Double] = [:]
        var playbackRateSavedBuckets: [Date: Double] = [:]
        var cursor = start
        while cursor < end {
            let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start ?? cursor
            let nextHour = calendar.date(byAdding: .hour, value: 1, to: hourStart) ?? end
            let blockEnd = min(nextHour, end)
            let seconds = blockEnd.timeIntervalSince(cursor)
            buckets[hourStart, default: 0] += seconds
            if savedSecondsTotal > 0, sessionDuration > 0 {
                savedBuckets[hourStart, default: 0] += savedSecondsTotal * (seconds / sessionDuration)
            }
            if playbackRateSavedSecondsTotal > 0, sessionDuration > 0 {
                playbackRateSavedBuckets[hourStart, default: 0] += playbackRateSavedSecondsTotal * (seconds / sessionDuration)
            }
            cursor = blockEnd
        }

        for (hourStart, seconds) in buckets where seconds > 0 {
            let predicate: Predicate<ListeningStat>
            if let podcastFeed {
                predicate = #Predicate<ListeningStat> { stat in
                    stat.startOfHour == hourStart && stat.podcastFeed == podcastFeed
                }
            } else {
                predicate = #Predicate<ListeningStat> { stat in
                    stat.startOfHour == hourStart && stat.podcastFeed == nil
                }
            }

            var descriptor = FetchDescriptor<ListeningStat>(predicate: predicate)
            descriptor.fetchLimit = 1
            guard ((try? modelContext.fetch(descriptor)) ?? []).isEmpty else { continue }

            modelContext.insert(
                ListeningStat(
                    id: UUID(),
                    startOfHour: hourStart,
                    podcastFeed: podcastFeed,
                    podcastName: podcastName,
                    totalSeconds: seconds,
                    silenceGapTimeSavedSeconds: savedBuckets[hourStart] ?? 0,
                    playbackRateTimeSavedSeconds: playbackRateSavedBuckets[hourStart] ?? 0
                )
            )
        }
    }

    private func rebuildSummariesFromListeningStats(preservedSummaries: [PlaySessionSummarySnapshot] = []) {
        var aggregations = summaryAggregationsFromListeningStats()
        restoreFallbackSummaries(from: preservedSummaries, into: &aggregations)
        replaceSummaries(with: aggregations)
    }

    private func summaryAggregationsFromListeningStats() -> [SummaryAggregationKey: SummaryAggregationValue] {
        var aggregations: [SummaryAggregationKey: SummaryAggregationValue] = [:]
        var offset = 0

        while true {
            var descriptor = FetchDescriptor<ListeningStat>(
                sortBy: [SortDescriptor(\.startOfHour, order: .forward)]
            )
            descriptor.fetchLimit = analyticsBatchSize
            descriptor.fetchOffset = offset

            let stats = (try? modelContext.fetch(descriptor)) ?? []
            if stats.isEmpty { break }

            for stat in stats {
                guard let startOfHour = stat.startOfHour, let totalSeconds = stat.totalSeconds, totalSeconds > 0 else {
                    continue
                }

                for period in PlaySessionSummaryPeriod.allCases where period != .forever {
                    let key = SummaryAggregationKey(
                        period: period,
                        periodStart: summaryPeriodStart(for: period, containing: startOfHour),
                        podcastFeed: stat.podcastFeed
                    )
                    var value = aggregations[key] ?? SummaryAggregationValue()
                    value.totalSeconds += totalSeconds
                    value.silenceGapTimeSavedSeconds += stat.silenceGapTimeSavedSeconds ?? 0
                    value.playbackRateTimeSavedSeconds += stat.playbackRateTimeSavedSeconds ?? 0
                    value.activeHourCount += 1
                    if value.podcastName == nil, let podcastName = stat.podcastName, !podcastName.isEmpty {
                        value.podcastName = podcastName
                    }
                    aggregations[key] = value
                }
            }

            if stats.count < analyticsBatchSize { break }
            offset += analyticsBatchSize
        }

        return aggregations
    }

    private func restoreFallbackSummaries(
        from preservedSummaries: [PlaySessionSummarySnapshot],
        into aggregations: inout [SummaryAggregationKey: SummaryAggregationValue]
    ) {
        for snapshot in preservedSummaries where snapshot.period == .day {
            let key = SummaryAggregationKey(period: snapshot.period, periodStart: snapshot.periodStart, podcastFeed: snapshot.podcastFeed)
            guard aggregations[key] == nil else { continue }
            aggregations[key] = SummaryAggregationValue(
                podcastName: snapshot.podcastName,
                totalSeconds: snapshot.totalSeconds,
                silenceGapTimeSavedSeconds: snapshot.silenceGapTimeSavedSeconds,
                playbackRateTimeSavedSeconds: snapshot.playbackRateTimeSavedSeconds,
                activeHourCount: snapshot.activeHourCount
            )
        }

        let sourceSnapshots = preservedSummaries + aggregations.map { key, value in
            PlaySessionSummarySnapshot(
                period: key.period,
                periodStart: key.periodStart,
                podcastFeed: key.podcastFeed,
                podcastName: value.podcastName,
                totalSeconds: value.totalSeconds,
                silenceGapTimeSavedSeconds: value.silenceGapTimeSavedSeconds,
                playbackRateTimeSavedSeconds: value.playbackRateTimeSavedSeconds,
                activeHourCount: value.activeHourCount
            )
        }

        for period in [PlaySessionSummaryPeriod.week, .month, .year] {
            let rollups = rollupSummaries(for: period, sourceSummaries: sourceSnapshots, preservedSummaries: preservedSummaries)
            for aggregation in rollups {
                let key = SummaryAggregationKey(
                    period: aggregation.period,
                    periodStart: aggregation.periodStart,
                    podcastFeed: aggregation.podcastFeed
                )
                guard aggregations[key] == nil else { continue }
                aggregations[key] = SummaryAggregationValue(
                    podcastName: aggregation.podcastName,
                    totalSeconds: aggregation.totalSeconds,
                    silenceGapTimeSavedSeconds: aggregation.silenceGapTimeSavedSeconds,
                    playbackRateTimeSavedSeconds: aggregation.playbackRateTimeSavedSeconds,
                    activeHourCount: aggregation.activeHourCount
                )
            }
        }
    }

    private func replaceSummaries(with aggregations: [SummaryAggregationKey: SummaryAggregationValue]) {
        deleteExistingSummariesInBatches()

        var insertedCount = 0
        for (key, value) in aggregations {
            guard value.totalSeconds > 0 else { continue }
            modelContext.insert(
                PlaySessionSummary(
                    id: UUID(),
                    periodKind: key.period.rawValue,
                    periodStart: key.periodStart,
                    podcastFeed: key.podcastFeed,
                    podcastName: value.podcastName,
                    totalSeconds: value.totalSeconds,
                    silenceGapTimeSavedSeconds: value.silenceGapTimeSavedSeconds,
                    playbackRateTimeSavedSeconds: value.playbackRateTimeSavedSeconds,
                    activeHourCount: value.activeHourCount
                )
            )
            insertedCount += 1
            if insertedCount.isMultiple(of: analyticsBatchSize) {
                modelContext.saveIfNeeded()
            }
        }

        modelContext.saveIfNeeded()
    }

    private func deleteExistingSummariesInBatches() {
        while true {
            var descriptor = FetchDescriptor<PlaySessionSummary>()
            descriptor.fetchLimit = analyticsBatchSize

            let summaries = (try? modelContext.fetch(descriptor)) ?? []
            if summaries.isEmpty { break }

            for summary in summaries {
                modelContext.delete(summary)
            }
            modelContext.saveIfNeeded()

            if summaries.count < analyticsBatchSize { break }
        }
    }

    private func rollupSummaries(
        for period: PlaySessionSummaryPeriod,
        sourceSummaries: [PlaySessionSummarySnapshot],
        preservedSummaries: [PlaySessionSummarySnapshot]
    ) -> [SummaryAggregation] {
        let sourcePeriods = sourcePeriodsForRollup(to: period)
        let combinedSources = sourceSummaries + preservedSummaries
        var bestByKey: [SummaryAggregationKey: PlaySessionSummarySnapshot] = [:]
        for snapshot in combinedSources where sourcePeriods.contains(snapshot.period) {
            let key = SummaryAggregationKey(
                period: snapshot.period,
                periodStart: snapshot.periodStart,
                podcastFeed: snapshot.podcastFeed
            )
            bestByKey[key] = snapshot
        }

        var selected: [PlaySessionSummarySnapshot] = []
        for sourcePeriod in sourcePeriods {
            let candidates = bestByKey.values
                .filter { $0.period == sourcePeriod }
                .sorted { $0.periodStart < $1.periodStart }

            for candidate in candidates {
                let candidateInterval = summaryInterval(for: candidate.period, periodStart: candidate.periodStart)
                let overlapsExisting = selected.contains { existing in
                    existing.podcastFeed == candidate.podcastFeed
                    && summaryPeriodStart(for: period, containing: existing.periodStart) == summaryPeriodStart(for: period, containing: candidate.periodStart)
                    && summaryInterval(for: existing.period, periodStart: existing.periodStart).intersects(candidateInterval)
                }
                if !overlapsExisting {
                    selected.append(candidate)
                }
            }
        }

        let grouped = Dictionary(grouping: selected) { snapshot in
            SummaryAggregationKey(
                period: period,
                periodStart: summaryPeriodStart(for: period, containing: snapshot.periodStart),
                podcastFeed: snapshot.podcastFeed
            )
        }

        return grouped.compactMap { key, values in
            let totalSeconds = values.reduce(0) { $0 + $1.totalSeconds }
            guard totalSeconds > 0 else { return nil }
            let silenceGapTimeSavedSeconds = values.reduce(0) { $0 + $1.silenceGapTimeSavedSeconds }
            let playbackRateTimeSavedSeconds = values.reduce(0) { $0 + $1.playbackRateTimeSavedSeconds }
            let activeHourCount = values.reduce(0) { $0 + $1.activeHourCount }
            let podcastName = values.first(where: { $0.podcastName?.isEmpty == false })?.podcastName
            return SummaryAggregation(
                period: key.period,
                periodStart: key.periodStart,
                podcastFeed: key.podcastFeed,
                podcastName: podcastName,
                totalSeconds: totalSeconds,
                silenceGapTimeSavedSeconds: silenceGapTimeSavedSeconds,
                playbackRateTimeSavedSeconds: playbackRateTimeSavedSeconds,
                activeHourCount: activeHourCount
            )
        }
    }

    private func sourcePeriodsForRollup(to period: PlaySessionSummaryPeriod) -> [PlaySessionSummaryPeriod] {
        switch period {
        case .day:
            return []
        case .week:
            return [.day, .week]
        case .month:
            return [.day, .week, .month]
        case .year:
            return [.day, .week, .month, .year]
        case .forever:
            return []
        }
    }

    private func existingSummaryKeys() -> Set<SummaryAggregationKey> {
        let summaries = (try? modelContext.fetch(FetchDescriptor<PlaySessionSummary>())) ?? []
        return Set(summaries.compactMap { summary in
            guard
                let periodKind = summary.periodKind,
                let period = PlaySessionSummaryPeriod(rawValue: periodKind),
                let periodStart = summary.periodStart
            else {
                return nil
            }
            return SummaryAggregationKey(period: period, periodStart: periodStart, podcastFeed: summary.podcastFeed)
        })
    }

    private func insertSummary(
        period: PlaySessionSummaryPeriod,
        periodStart: Date,
        podcastFeed: URL?,
        podcastName: String?,
        totalSeconds: Double,
        silenceGapTimeSavedSeconds: Double,
        playbackRateTimeSavedSeconds: Double,
        activeHourCount: Int
    ) {
        modelContext.insert(
            PlaySessionSummary(
                id: UUID(),
                periodKind: period.rawValue,
                periodStart: periodStart,
                podcastFeed: podcastFeed,
                podcastName: podcastName,
                totalSeconds: totalSeconds,
                silenceGapTimeSavedSeconds: silenceGapTimeSavedSeconds,
                playbackRateTimeSavedSeconds: playbackRateTimeSavedSeconds,
                activeHourCount: activeHourCount
            )
        )
    }

    // Recovery logic: On launch, check if a session was left open, and finalize it
    private func recoverIncompleteSessionIfNeeded()  {
        let allSessions = (try? modelContext.fetch(FetchDescriptor<PlaySession>())) ?? []
        guard !allSessions.isEmpty else { return }
        var didMutateSessions = false

        var sessionsByEpisode: [PersistentIdentifier: [PlaySession]] = [:]
        for session in allSessions {
            guard let episode = session.episode else { continue }
            sessionsByEpisode[episode.persistentModelID, default: []].append(session)
        }

        for sessionsForEpisode in sessionsByEpisode.values {
            let sortedByStart = sessionsForEpisode.sorted {
                ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast)
            }

            for (index, session) in sortedByStart.enumerated() {
                guard session.endTime == nil,
                      let episode = session.episode,
                      let sessionStartPosition = session.startPosition else { continue }

                let nextSession: PlaySession?
                if index + 1 < sortedByStart.count {
                    nextSession = sortedByStart[(index + 1)...].first(where: { $0.startTime != nil })
                } else {
                    nextSession = nil
                }
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
                recordSilenceGapTimeSavedForEpisode(session)
                let touchedHours = recordListeningStats(for: session)
                rebuildSummaries(forHourStarts: touchedHours, podcastFeed: episode.podcast?.feed, podcastName: session.podcastName)
                didMutateSessions = true
            }
        }
        }

        if didMutateSessions {
            modelContext.saveIfNeeded()
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
        case .forever:
            return .distantPast
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
        case .forever:
            end = .distantFuture
        }
        return DateInterval(start: periodStart, end: end)
    }



    private func saveSession() {
        modelContext.saveIfNeeded()
    }

    // MARK: - Device Info Helpers

    private func getDeviceModel() async -> String {
#if os(iOS)
        return await MainActor.run { UIDevice.current.model }
#elseif os(macOS)
        return "Mac"
#else
        return "Unknown"
#endif
    }

    private func getOSVersion() async -> String {
#if os(iOS)
        return await MainActor.run { UIDevice.current.systemVersion }
#elseif os(macOS)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
#else
        return "Unknown"
#endif
    }
}
