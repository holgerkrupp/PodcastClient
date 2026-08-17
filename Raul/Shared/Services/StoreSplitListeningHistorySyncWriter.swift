import Foundation
import SwiftData

struct StoreSplitListeningHistorySnapshot: Sendable {
    let id: String
    let identity: EpisodeStableIdentity
    let podcastName: String
    let episodeTitle: String
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
}

@ModelActor
actor StoreSplitListeningHistorySyncWriter {
    func upsert(_ snapshot: StoreSplitListeningHistorySnapshot) {
        upsertWithoutSaving(snapshot)
        rebuildLiveSummaries(changedSnapshots: [snapshot], reference: snapshot)
        modelContext.saveIfNeeded()
    }

    func upsert(_ snapshots: [StoreSplitListeningHistorySnapshot]) {
        var summarySources: [String: [StoreSplitListeningHistorySnapshot]] = [:]
        for snapshot in snapshots {
            upsertWithoutSaving(snapshot)
            let key = StableIdentityKey.make(
                snapshot.sourceDeviceID,
                snapshot.identity.feedURL
            )
            summarySources[key, default: []].append(snapshot)
        }
        for changedSnapshots in summarySources.values {
            guard let reference = changedSnapshots.last else { continue }
            rebuildLiveSummaries(
                changedSnapshots: changedSnapshots,
                reference: reference
            )
        }
        modelContext.saveIfNeeded()
    }

    private func upsertWithoutSaving(
        _ snapshot: StoreSplitListeningHistorySnapshot
    ) {
        let historyID = snapshot.id
        let descriptor = FetchDescriptor<ListeningHistorySync>(
            predicate: #Predicate<ListeningHistorySync> { $0.id == historyID }
        )
        if let record = try? modelContext.fetch(descriptor).first {
            guard snapshot.endedAt > record.updatedAt else { return }
            apply(snapshot, to: record)
        } else {
            modelContext.insert(
                ListeningHistorySync(
                    id: snapshot.id,
                    feedURL: snapshot.identity.feedURL,
                    episodeID: snapshot.identity.episodeID,
                    podcastName: snapshot.podcastName,
                    episodeTitle: snapshot.episodeTitle,
                    sourceDeviceID: snapshot.sourceDeviceID,
                    sourceDeviceName: snapshot.sourceDeviceName,
                    deviceModel: snapshot.deviceModel,
                    startedAt: snapshot.startedAt,
                    endedAt: snapshot.endedAt,
                    startPosition: snapshot.startPosition,
                    endPosition: snapshot.endPosition,
                    listenedSeconds: snapshot.listenedSeconds,
                    silenceGapTimeSavedSeconds: snapshot.silenceGapTimeSavedSeconds,
                    playbackRateTimeSavedSeconds: snapshot.playbackRateTimeSavedSeconds,
                    endedCleanly: snapshot.endedCleanly,
                    updatedAt: snapshot.endedAt
                )
            )
        }
    }

    private func apply(
        _ snapshot: StoreSplitListeningHistorySnapshot,
        to record: ListeningHistorySync
    ) {
        record.feedURL = snapshot.identity.feedURL
        record.episodeID = snapshot.identity.episodeID
        record.podcastName = snapshot.podcastName
        record.episodeTitle = snapshot.episodeTitle
        record.sourceDeviceID = snapshot.sourceDeviceID
        record.sourceDeviceName = snapshot.sourceDeviceName
        record.deviceModel = snapshot.deviceModel
        record.startedAt = snapshot.startedAt
        record.endedAt = snapshot.endedAt
        record.startPosition = snapshot.startPosition
        record.endPosition = snapshot.endPosition
        record.listenedSeconds = snapshot.listenedSeconds
        record.silenceGapTimeSavedSeconds = snapshot.silenceGapTimeSavedSeconds
        record.playbackRateTimeSavedSeconds = snapshot.playbackRateTimeSavedSeconds
        record.endedCleanly = snapshot.endedCleanly
        record.isLegacyMigrated = false
        record.updatedAt = snapshot.endedAt
    }

    /// Recomputes absolute per-device rows from live compact history. Absolute
    /// totals make a retry harmless and avoid increment-vs-CloudKit conflicts.
    /// Migrated rows are excluded because `__legacy_shared__` summaries already
    /// contain their historical contribution.
    private func rebuildLiveSummaries(
        changedSnapshots: [StoreSplitListeningHistorySnapshot],
        reference snapshot: StoreSplitListeningHistorySnapshot
    ) {
        let deviceID = snapshot.sourceDeviceID
        var offset = 0
        let pageSize = 250
        var newestByIdentity: [String: ListeningHistorySync] = [:]
        let targetFeedKeys = URL(string: snapshot.identity.feedURL)?
            .podcastFeedComparisonKeys ?? Set([snapshot.identity.feedURL])

        while true {
            var descriptor = FetchDescriptor<ListeningHistorySync>(
                predicate: #Predicate {
                    $0.sourceDeviceID == deviceID && $0.isLegacyMigrated == false
                },
                sortBy: [SortDescriptor(\ListeningHistorySync.updatedAt, order: .reverse)]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = pageSize
            let page = (try? modelContext.fetch(descriptor)) ?? []
            guard page.isEmpty == false else { break }

            for record in page {
                let matchesFeed: Bool
                if let recordURL = URL(string: record.feedURL) {
                    matchesFeed = recordURL.podcastFeedComparisonKeys
                        .isDisjoint(with: targetFeedKeys) == false
                } else {
                    matchesFeed = record.feedURL == snapshot.identity.feedURL
                }
                guard matchesFeed else { continue }
                let key = ListeningHistoryIdentity.canonicalAggregationKey(for: record)
                if newestByIdentity[key] == nil {
                    newestByIdentity[key] = record
                }
            }

            offset += page.count
            if page.count < pageSize { break }
        }

        let calendar = Calendar.current
        for period in PlaySessionSummaryPeriod.allCases {
            let affectedStarts = Set(changedSnapshots.flatMap {
                touchedPeriodStarts(
                    for: period,
                    from: $0.startedAt,
                    to: $0.endedAt,
                    calendar: calendar
                )
            })
            for start in affectedStarts {
                let end = summaryPeriodEnd(
                    for: period,
                    start: start,
                    calendar: calendar
                )
                let contributions = newestByIdentity.values.compactMap {
                    contribution(
                        from: $0,
                        period: period,
                        start: start,
                        end: end
                    )
                }
                let totals = contributions.reduce(
                    into: (listened: 0.0, silence: 0.0, rate: 0.0)
                ) { total, contribution in
                    total.listened += contribution.listened
                    total.silence += contribution.silence
                    total.rate += contribution.rate
                }
                let activeHours = Set(contributions.flatMap { contribution in
                    touchedHourStarts(
                        from: contribution.overlapStart,
                        to: contribution.overlapEnd,
                        calendar: calendar
                    )
                }).count
                upsertSummary(
                    ListeningSummarySync(
                        feedURL: snapshot.identity.feedURL,
                        periodKind: period.rawValue,
                        periodStart: start,
                        sourceDeviceID: deviceID,
                        sourceDeviceName: snapshot.sourceDeviceName,
                        sourceDeviceModel: snapshot.deviceModel,
                        podcastName: snapshot.podcastName,
                        totalSeconds: totals.listened,
                        silenceGapTimeSavedSeconds: totals.silence,
                        playbackRateTimeSavedSeconds: totals.rate,
                        activeHourCount: activeHours,
                        updatedAt: .now
                    )
                )
            }
        }
    }

    private func upsertSummary(_ candidate: ListeningSummarySync) {
        let summaryID = candidate.id
        var descriptor = FetchDescriptor<ListeningSummarySync>(
            predicate: #Predicate { $0.id == summaryID }
        )
        descriptor.fetchLimit = 1
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.feedURL = candidate.feedURL
            existing.periodKind = candidate.periodKind
            existing.periodStart = candidate.periodStart
            existing.sourceDeviceID = candidate.sourceDeviceID
            existing.sourceDeviceName = candidate.sourceDeviceName
            existing.sourceDeviceModel = candidate.sourceDeviceModel
            existing.podcastName = candidate.podcastName
            existing.totalSeconds = candidate.totalSeconds
            existing.silenceGapTimeSavedSeconds = candidate.silenceGapTimeSavedSeconds
            existing.playbackRateTimeSavedSeconds = candidate.playbackRateTimeSavedSeconds
            existing.activeHourCount = candidate.activeHourCount
            existing.updatedAt = candidate.updatedAt
        } else {
            modelContext.insert(candidate)
        }
    }

    private func touchedPeriodStarts(
        for period: PlaySessionSummaryPeriod,
        from start: Date,
        to end: Date,
        calendar: Calendar
    ) -> [Date] {
        if period == .forever { return [.distantPast] }
        guard end > start else {
            return [summaryPeriodStart(for: period, containing: start, calendar: calendar)]
        }
        var result: [Date] = []
        var cursor = summaryPeriodStart(
            for: period,
            containing: start,
            calendar: calendar
        )
        while cursor < end {
            result.append(cursor)
            let next = summaryPeriodEnd(for: period, start: cursor, calendar: calendar)
            guard next > cursor else { break }
            cursor = next
        }
        return result
    }

    private func contribution(
        from record: ListeningHistorySync,
        period: PlaySessionSummaryPeriod,
        start: Date,
        end: Date
    ) -> (
        listened: Double,
        silence: Double,
        rate: Double,
        overlapStart: Date,
        overlapEnd: Date
    )? {
        if period == .forever {
            return (
                max(0, record.listenedSeconds),
                max(0, record.silenceGapTimeSavedSeconds),
                max(0, record.playbackRateTimeSavedSeconds),
                record.startedAt,
                record.endedAt
            )
        }
        let overlapStart = max(record.startedAt, start)
        let overlapEnd = min(record.endedAt, end)
        guard overlapEnd > overlapStart else { return nil }
        let wallDuration = max(record.endedAt.timeIntervalSince(record.startedAt), 0)
        let fraction = wallDuration > 0
            ? overlapEnd.timeIntervalSince(overlapStart) / wallDuration
            : 0
        return (
            max(0, record.listenedSeconds) * fraction,
            max(0, record.silenceGapTimeSavedSeconds) * fraction,
            max(0, record.playbackRateTimeSavedSeconds) * fraction,
            overlapStart,
            overlapEnd
        )
    }

    private func summaryPeriodStart(
        for period: PlaySessionSummaryPeriod,
        containing date: Date,
        calendar: Calendar
    ) -> Date {
        switch period {
        case .day:
            calendar.startOfDay(for: date)
        case .week:
            calendar.date(from: calendar.dateComponents(
                [.yearForWeekOfYear, .weekOfYear],
                from: date
            )) ?? calendar.startOfDay(for: date)
        case .month:
            calendar.date(from: calendar.dateComponents([.year, .month], from: date))
                ?? calendar.startOfDay(for: date)
        case .year:
            calendar.date(from: calendar.dateComponents([.year], from: date))
                ?? calendar.startOfDay(for: date)
        case .forever:
            .distantPast
        }
    }

    private func summaryPeriodEnd(
        for period: PlaySessionSummaryPeriod,
        start: Date,
        calendar: Calendar
    ) -> Date {
        switch period {
        case .day:
            calendar.date(byAdding: .day, value: 1, to: start) ?? .distantFuture
        case .week:
            calendar.date(byAdding: .weekOfYear, value: 1, to: start) ?? .distantFuture
        case .month:
            calendar.date(byAdding: .month, value: 1, to: start) ?? .distantFuture
        case .year:
            calendar.date(byAdding: .year, value: 1, to: start) ?? .distantFuture
        case .forever:
            .distantFuture
        }
    }

    private func touchedHourStarts(
        from start: Date,
        to end: Date,
        calendar: Calendar
    ) -> [Date] {
        guard end > start else { return [] }
        var result: [Date] = []
        var cursor = start
        while cursor < end {
            let hour = calendar.dateInterval(of: .hour, for: cursor)?.start ?? cursor
            result.append(hour)
            cursor = calendar.date(byAdding: .hour, value: 1, to: hour) ?? end
        }
        return result
    }
}
