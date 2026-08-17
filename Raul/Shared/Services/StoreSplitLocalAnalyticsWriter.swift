import Foundation
import SwiftData

struct StoreSplitLocalRateSegmentSnapshot: Sendable {
    let rate: Float
    let startTime: Date?
    let startPosition: Double?
    let endTime: Date?
    let endPosition: Double?
}

struct StoreSplitLocalAnalyticsSessionSnapshot: Sendable {
    let sessionID: String
    let identity: EpisodeStableIdentity
    let podcastName: String?
    let episodeTitle: String?
    let sourceDeviceID: String
    let sourceDeviceName: String?
    let deviceModel: String?
    let osVersion: String?
    let appVersion: String?
    let startedAt: Date
    let endedAt: Date?
    let startPosition: Double
    let endPosition: Double?
    let silenceGapTimeSavedSeconds: Double
    let playbackRateTimeSavedSeconds: Double
    let endedCleanly: Bool
    let rateSegments: [StoreSplitLocalRateSegmentSnapshot]
}

/// Durable, local-only analytics writer. Child rows are replaced atomically so
/// repeated progress/finalization writes cannot increment totals twice.
@ModelActor
actor StoreSplitLocalAnalyticsWriter {
    private let retentionDays = 30

    func upsert(_ snapshot: StoreSplitLocalAnalyticsSessionSnapshot) {
        let sessionID = snapshot.sessionID
        var descriptor = FetchDescriptor<CachedPlaySession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        descriptor.fetchLimit = 1
        let record = (try? modelContext.fetch(descriptor).first)
            ?? CachedPlaySession(
                id: sessionID,
                feedURL: snapshot.identity.feedURL,
                episodeID: snapshot.identity.episodeID,
                sourceDeviceID: snapshot.sourceDeviceID,
                startedAt: snapshot.startedAt
            )
        if record.modelContext == nil { modelContext.insert(record) }

        record.feedURL = snapshot.identity.feedURL
        record.episodeID = snapshot.identity.episodeID
        record.podcastName = snapshot.podcastName
        record.episodeTitle = snapshot.episodeTitle
        record.sourceDeviceID = snapshot.sourceDeviceID
        record.sourceDeviceName = snapshot.sourceDeviceName
        record.deviceModel = snapshot.deviceModel
        record.osVersion = snapshot.osVersion
        record.appVersion = snapshot.appVersion
        record.startedAt = snapshot.startedAt
        record.endedAt = snapshot.endedAt
        record.startPosition = snapshot.startPosition
        record.endPosition = snapshot.endPosition
        record.silenceGapTimeSavedSeconds = max(0, snapshot.silenceGapTimeSavedSeconds)
        record.playbackRateTimeSavedSeconds = max(0, snapshot.playbackRateTimeSavedSeconds)
        record.endedCleanly = snapshot.endedCleanly
        record.updatedAt = .now

        replaceRateSegments(for: snapshot)
        replaceHourlyContributions(for: snapshot)
        pruneExpiredSessions()
        modelContext.saveIfNeeded()
    }

    private func replaceRateSegments(
        for snapshot: StoreSplitLocalAnalyticsSessionSnapshot
    ) {
        let sessionID = snapshot.sessionID
        let descriptor = FetchDescriptor<CachedRateSegment>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        for existing in (try? modelContext.fetch(descriptor)) ?? [] {
            modelContext.delete(existing)
        }
        for (ordinal, segment) in snapshot.rateSegments.enumerated() {
            modelContext.insert(CachedRateSegment(
                id: StableIdentityKey.make(sessionID, "rate", String(ordinal)),
                sessionID: sessionID,
                ordinal: ordinal,
                rate: segment.rate,
                startTime: segment.startTime,
                startPosition: segment.startPosition,
                endTime: segment.endTime,
                endPosition: segment.endPosition
            ))
        }
    }

    private func replaceHourlyContributions(
        for snapshot: StoreSplitLocalAnalyticsSessionSnapshot
    ) {
        let sessionID = snapshot.sessionID
        let descriptor = FetchDescriptor<CachedHourlyListeningStat>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        for existing in (try? modelContext.fetch(descriptor)) ?? [] {
            modelContext.delete(existing)
        }

        guard let endedAt = snapshot.endedAt,
              endedAt > snapshot.startedAt else { return }
        let duration = endedAt.timeIntervalSince(snapshot.startedAt)
        guard duration.isFinite, duration > 0 else { return }

        let calendar = Calendar.current
        var cursor = snapshot.startedAt
        while cursor < endedAt {
            let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start
                ?? cursor
            let nextHour = calendar.date(byAdding: .hour, value: 1, to: hourStart)
                ?? endedAt
            let blockEnd = min(nextHour, endedAt)
            let seconds = blockEnd.timeIntervalSince(cursor)
            let fraction = seconds / duration
            modelContext.insert(CachedHourlyListeningStat(
                id: StableIdentityKey.make(
                    sessionID,
                    "hour",
                    String(Int(hourStart.timeIntervalSince1970))
                ),
                sessionID: sessionID,
                feedURL: snapshot.identity.feedURL,
                podcastName: snapshot.podcastName,
                sourceDeviceID: snapshot.sourceDeviceID,
                startOfHour: hourStart,
                totalSeconds: seconds,
                silenceGapTimeSavedSeconds:
                    max(0, snapshot.silenceGapTimeSavedSeconds) * fraction,
                playbackRateTimeSavedSeconds:
                    max(0, snapshot.playbackRateTimeSavedSeconds) * fraction
            ))
            cursor = blockEnd
        }
    }

    private func pruneExpiredSessions() {
        guard let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -retentionDays,
            to: .now
        ) else { return }
        while true {
            var descriptor = FetchDescriptor<CachedPlaySession>(
                predicate: #Predicate {
                    $0.endedAt != nil && $0.endedAt! < cutoff
                }
            )
            descriptor.fetchLimit = 100
            let page = (try? modelContext.fetch(descriptor)) ?? []
            guard page.isEmpty == false else { break }
            for session in page {
                let sessionID = session.id
                let rates = FetchDescriptor<CachedRateSegment>(
                    predicate: #Predicate { $0.sessionID == sessionID }
                )
                for rate in (try? modelContext.fetch(rates)) ?? [] {
                    modelContext.delete(rate)
                }
                let hours = FetchDescriptor<CachedHourlyListeningStat>(
                    predicate: #Predicate { $0.sessionID == sessionID }
                )
                for hour in (try? modelContext.fetch(hours)) ?? [] {
                    modelContext.delete(hour)
                }
                modelContext.delete(session)
            }
            modelContext.saveIfNeeded()
            if page.count < 100 { break }
        }
    }
}
