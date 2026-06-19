import Foundation
import SwiftData
import CryptoKit

@Model
final class SubscriptionSync: Identifiable {
    var id: String = ""
    var feedURL: String = ""
    var isSubscribed: Bool = true
    var titleOverride: String?
    var displaySettingsRawValue: String?
    var subscribedAt: Date = Date.distantPast
    var unsubscribedAt: Date?
    var updatedAt: Date = Date.distantPast
    var sourceDeviceID: String?

    init(
        feedURL: String,
        isSubscribed: Bool = true,
        titleOverride: String? = nil,
        displaySettingsRawValue: String? = nil,
        subscribedAt: Date = .now,
        unsubscribedAt: Date? = nil,
        updatedAt: Date = .now,
        sourceDeviceID: String? = nil
    ) {
        self.id = feedURL
        self.feedURL = feedURL
        self.isSubscribed = isSubscribed
        self.titleOverride = titleOverride
        self.displaySettingsRawValue = displaySettingsRawValue
        self.subscribedAt = subscribedAt
        self.unsubscribedAt = unsubscribedAt
        self.updatedAt = updatedAt
        self.sourceDeviceID = sourceDeviceID
    }
}

@Model
final class EpisodeStateSync: Identifiable {
    var id: String = ""
    var feedURL: String = ""
    var episodeID: String = ""
    var playPosition: Double = 0
    var maxPlayPosition: Double = 0
    var duration: Double?
    var isPlayed: Bool = false
    var isArchived: Bool = false
    var wasSkipped: Bool = false
    var completedAt: Date?
    var archivedAt: Date?
    var firstPlayedAt: Date?
    var lastPlayedAt: Date?
    var updatedAt: Date = Date.distantPast
    var sourceDeviceID: String?

    init(
        feedURL: String,
        episodeID: String,
        playPosition: Double = 0,
        maxPlayPosition: Double = 0,
        duration: Double? = nil,
        isPlayed: Bool = false,
        isArchived: Bool = false,
        wasSkipped: Bool = false,
        completedAt: Date? = nil,
        archivedAt: Date? = nil,
        firstPlayedAt: Date? = nil,
        lastPlayedAt: Date? = nil,
        updatedAt: Date = .now,
        sourceDeviceID: String? = nil
    ) {
        self.id = StableIdentityKey.make(feedURL, episodeID)
        self.feedURL = feedURL
        self.episodeID = episodeID
        self.playPosition = playPosition
        self.maxPlayPosition = maxPlayPosition
        self.duration = duration
        self.isPlayed = isPlayed
        self.isArchived = isArchived
        self.wasSkipped = wasSkipped
        self.completedAt = completedAt
        self.archivedAt = archivedAt
        self.firstPlayedAt = firstPlayedAt
        self.lastPlayedAt = lastPlayedAt
        self.updatedAt = updatedAt
        self.sourceDeviceID = sourceDeviceID
    }
}

@Model
final class QueueEntrySync: Identifiable {
    var id: String = ""
    var feedURL: String = ""
    var episodeID: String = ""
    var sortIndex: Int = 0
    var addedAt: Date = Date.distantPast
    var isDeleted: Bool = false
    var deletedAt: Date?
    var updatedAt: Date = Date.distantPast
    var sourceDeviceID: String?

    init(
        feedURL: String,
        episodeID: String,
        sortIndex: Int,
        addedAt: Date = .now,
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        updatedAt: Date = .now,
        sourceDeviceID: String? = nil
    ) {
        self.id = StableIdentityKey.make(feedURL, episodeID)
        self.feedURL = feedURL
        self.episodeID = episodeID
        self.sortIndex = sortIndex
        self.addedAt = addedAt
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.updatedAt = updatedAt
        self.sourceDeviceID = sourceDeviceID
    }
}

@Model
final class PlaylistSync: Identifiable {
    var id: String = ""
    var title: String = ""
    var symbolName: String = ""
    var sortIndex: Int = 0
    var kindRawValue: String = ""
    var smartFilterRawValue: String?
    var isHidden: Bool = false
    var isDeleted: Bool = false
    var deletedAt: Date?
    var createdAt: Date = Date.distantPast
    var updatedAt: Date = Date.distantPast
    var sourceDeviceID: String?

    init(
        id: String,
        title: String,
        symbolName: String,
        sortIndex: Int,
        kindRawValue: String,
        smartFilterRawValue: String? = nil,
        isHidden: Bool = false,
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        sourceDeviceID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.sortIndex = sortIndex
        self.kindRawValue = kindRawValue
        self.smartFilterRawValue = smartFilterRawValue
        self.isHidden = isHidden
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceDeviceID = sourceDeviceID
    }
}

@Model
final class PlaylistEntrySync: Identifiable {
    var id: String = ""
    var playlistID: String = ""
    var feedURL: String = ""
    var episodeID: String = ""
    var sortIndex: Int = 0
    var addedAt: Date = Date.distantPast
    var isDeleted: Bool = false
    var deletedAt: Date?
    var updatedAt: Date = Date.distantPast
    var sourceDeviceID: String?

    init(
        playlistID: String,
        feedURL: String,
        episodeID: String,
        sortIndex: Int,
        addedAt: Date = .now,
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        updatedAt: Date = .now,
        sourceDeviceID: String? = nil
    ) {
        self.id = StableIdentityKey.make(playlistID, feedURL, episodeID)
        self.playlistID = playlistID
        self.feedURL = feedURL
        self.episodeID = episodeID
        self.sortIndex = sortIndex
        self.addedAt = addedAt
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.updatedAt = updatedAt
        self.sourceDeviceID = sourceDeviceID
    }
}

@Model
final class BookmarkSync: Identifiable {
    var id: String = ""
    var feedURL: String = ""
    var episodeID: String = ""
    var time: Double = 0
    var title: String?
    var note: String?
    var createdAt: Date = Date.distantPast
    var isDeleted: Bool = false
    var deletedAt: Date?
    var updatedAt: Date = Date.distantPast
    var sourceDeviceID: String?

    init(
        id: String = UUID().uuidString,
        feedURL: String,
        episodeID: String,
        time: Double,
        title: String? = nil,
        note: String? = nil,
        createdAt: Date = .now,
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        updatedAt: Date = .now,
        sourceDeviceID: String? = nil
    ) {
        self.id = id
        self.feedURL = feedURL
        self.episodeID = episodeID
        self.time = time
        self.title = title
        self.note = note
        self.createdAt = createdAt
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.updatedAt = updatedAt
        self.sourceDeviceID = sourceDeviceID
    }
}

@Model
final class ListeningSummarySync: Identifiable {
    var id: String = ""
    var feedURL: String = ""
    var periodKind: String = ""
    var periodStart: Date = Date.distantPast
    var sourceDeviceID: String?
    var sourceDeviceName: String?
    var podcastName: String?
    var totalSeconds: Double = 0
    var silenceGapTimeSavedSeconds: Double = 0
    var playbackRateTimeSavedSeconds: Double = 0
    var activeHourCount: Int = 0
    var updatedAt: Date = Date.distantPast

    init(
        feedURL: String,
        periodKind: String,
        periodStart: Date,
        sourceDeviceID: String? = nil,
        sourceDeviceName: String? = nil,
        podcastName: String? = nil,
        totalSeconds: Double = 0,
        silenceGapTimeSavedSeconds: Double = 0,
        playbackRateTimeSavedSeconds: Double = 0,
        activeHourCount: Int = 0,
        updatedAt: Date = .now
    ) {
        self.id = StableIdentityKey.make(
            feedURL,
            periodKind,
            String(Int(periodStart.timeIntervalSince1970)),
            sourceDeviceID ?? "__unknown_device__"
        )
        self.feedURL = feedURL
        self.periodKind = periodKind
        self.periodStart = periodStart
        self.sourceDeviceID = sourceDeviceID
        self.sourceDeviceName = sourceDeviceName
        self.podcastName = podcastName
        self.totalSeconds = totalSeconds
        self.silenceGapTimeSavedSeconds = silenceGapTimeSavedSeconds
        self.playbackRateTimeSavedSeconds = playbackRateTimeSavedSeconds
        self.activeHourCount = activeHourCount
        self.updatedAt = updatedAt
    }

    var aggregationKey: String {
        return StableIdentityKey.make(
            feedURL,
            periodKind,
            String(Int(periodStart.timeIntervalSince1970))
        )
    }
}

@Model
final class ListeningHistorySync: Identifiable {
    var id: String = ""
    var feedURL: String = ""
    var episodeID: String = ""
    var podcastName: String?
    var episodeTitle: String?
    var sourceDeviceID: String = ""
    var sourceDeviceName: String?
    var deviceModel: String?
    var startedAt: Date = Date.distantPast
    var endedAt: Date = Date.distantPast
    var startPosition: Double = 0
    var endPosition: Double = 0
    var listenedSeconds: Double = 0
    var silenceGapTimeSavedSeconds: Double = 0
    var playbackRateTimeSavedSeconds: Double = 0
    var endedCleanly: Bool = false
    var updatedAt: Date = Date.distantPast

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
        updatedAt: Date = .now
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
        self.updatedAt = updatedAt
    }
}

@Model
final class AITranscriptSync: Identifiable {
    var id: String = ""
    var feedURL: String = ""
    var episodeID: String = ""
    var revisionID: String = ""
    var localeIdentifier: String?
    var chunkCount: Int = 0
    var lineCount: Int = 0
    var contentHash: String = ""
    var generatedAt: Date = Date.distantPast
    var deletedAt: Date?
    var updatedAt: Date = Date.distantPast
    var sourceDeviceID: String?

    init(
        feedURL: String,
        episodeID: String,
        revisionID: String,
        localeIdentifier: String? = nil,
        chunkCount: Int,
        lineCount: Int,
        contentHash: String,
        generatedAt: Date,
        deletedAt: Date? = nil,
        updatedAt: Date = .now,
        sourceDeviceID: String? = nil
    ) {
        self.id = StableIdentityKey.make(feedURL, episodeID)
        self.feedURL = feedURL
        self.episodeID = episodeID
        self.revisionID = revisionID
        self.localeIdentifier = localeIdentifier
        self.chunkCount = chunkCount
        self.lineCount = lineCount
        self.contentHash = contentHash
        self.generatedAt = generatedAt
        self.deletedAt = deletedAt
        self.updatedAt = updatedAt
        self.sourceDeviceID = sourceDeviceID
    }
}

@Model
final class AITranscriptChunkSync: Identifiable {
    var id: String = ""
    var transcriptID: String = ""
    var revisionID: String = ""
    var chunkIndex: Int = 0
    var payloadJSON: String = ""
    var contentHash: String = ""
    var updatedAt: Date = Date.distantPast

    init(
        transcriptID: String,
        revisionID: String,
        chunkIndex: Int,
        payloadJSON: String,
        contentHash: String,
        updatedAt: Date = .now
    ) {
        self.id = StableIdentityKey.make(
            transcriptID,
            revisionID,
            String(chunkIndex)
        )
        self.transcriptID = transcriptID
        self.revisionID = revisionID
        self.chunkIndex = chunkIndex
        self.payloadJSON = payloadJSON
        self.contentHash = contentHash
        self.updatedAt = updatedAt
    }
}

@Model
final class AIChapterSetSync: Identifiable {
    var id: String = ""
    var feedURL: String = ""
    var episodeID: String = ""
    var revisionID: String = ""
    var payloadJSON: String = ""
    var chapterCount: Int = 0
    var contentHash: String = ""
    var generatedAt: Date = Date.distantPast
    var updatedAt: Date = Date.distantPast
    var sourceDeviceID: String?

    init(
        feedURL: String,
        episodeID: String,
        revisionID: String,
        payloadJSON: String,
        chapterCount: Int,
        contentHash: String,
        generatedAt: Date,
        updatedAt: Date = .now,
        sourceDeviceID: String? = nil
    ) {
        self.id = StableIdentityKey.make(feedURL, episodeID)
        self.feedURL = feedURL
        self.episodeID = episodeID
        self.revisionID = revisionID
        self.payloadJSON = payloadJSON
        self.chapterCount = chapterCount
        self.contentHash = contentHash
        self.generatedAt = generatedAt
        self.updatedAt = updatedAt
        self.sourceDeviceID = sourceDeviceID
    }
}

struct AITranscriptLineValue: Codable, Equatable, Sendable {
    let speaker: String?
    let text: String
    let startTime: Double
    let endTime: Double?
}

struct AIChapterValue: Codable, Equatable, Sendable {
    let title: String
    let startTime: Double
    let duration: Double?
}

struct AITranscriptEncodedRevision: Equatable, Sendable {
    let revisionID: String
    let contentHash: String
    let chunks: [String]
    let lineCount: Int
}

enum AIContentSyncCodec {
    static let maximumTranscriptChunkBytes = 128 * 1024

    static func encodeTranscript(
        _ lines: [AITranscriptLineValue],
        maximumChunkBytes: Int = maximumTranscriptChunkBytes
    ) throws -> AITranscriptEncodedRevision {
        let orderedLines = lines.sorted {
            if $0.startTime != $1.startTime {
                return $0.startTime < $1.startTime
            }
            return $0.text < $1.text
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fullData = try encoder.encode(orderedLines)
        let contentHash = sha256Hex(fullData)
        var chunks: [String] = []
        var currentLines: [AITranscriptLineValue] = []

        for line in orderedLines {
            let candidate = currentLines + [line]
            let candidateData = try encoder.encode(candidate)
            if candidateData.count > maximumChunkBytes, currentLines.isEmpty == false {
                chunks.append(String(decoding: try encoder.encode(currentLines), as: UTF8.self))
                currentLines = [line]
            } else {
                currentLines = candidate
            }
        }

        if currentLines.isEmpty == false || orderedLines.isEmpty {
            chunks.append(String(decoding: try encoder.encode(currentLines), as: UTF8.self))
        }

        return AITranscriptEncodedRevision(
            revisionID: contentHash,
            contentHash: contentHash,
            chunks: chunks,
            lineCount: orderedLines.count
        )
    }

    static func decodeTranscript(
        chunks: [String],
        expectedLineCount: Int,
        expectedContentHash: String
    ) throws -> [AITranscriptLineValue] {
        let decoder = JSONDecoder()
        let lines = try chunks.flatMap {
            try decoder.decode([AITranscriptLineValue].self, from: Data($0.utf8))
        }
        guard lines.count == expectedLineCount else {
            throw AIContentSyncCodecError.lineCountMismatch
        }

        let encoded = try encodeTranscript(lines)
        guard encoded.contentHash == expectedContentHash else {
            throw AIContentSyncCodecError.contentHashMismatch
        }
        return lines
    }

    static func encodeChapters(_ chapters: [AIChapterValue]) throws -> (payload: String, hash: String) {
        let ordered = chapters.sorted {
            if $0.startTime != $1.startTime {
                return $0.startTime < $1.startTime
            }
            return $0.title < $1.title
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ordered)
        return (String(decoding: data, as: UTF8.self), sha256Hex(data))
    }

    static func decodeChapters(
        payloadJSON: String,
        expectedContentHash: String
    ) throws -> [AIChapterValue] {
        let data = Data(payloadJSON.utf8)
        guard sha256Hex(data) == expectedContentHash else {
            throw AIContentSyncCodecError.contentHashMismatch
        }
        return try JSONDecoder().decode([AIChapterValue].self, from: data)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum AIContentSyncCodecError: Error {
    case lineCountMismatch
    case contentHashMismatch
}

struct GlobalListeningStatistics: Equatable, Sendable {
    var totalSeconds: Double
    var silenceGapTimeSavedSeconds: Double
    var playbackRateTimeSavedSeconds: Double
    var sessionCount: Int
}

enum ListeningHistoryIdentity {
    static func make(
        feedURL: String,
        episodeID: String,
        startedAt: Date,
        endedAt: Date,
        startPosition: Double,
        endPosition: Double
    ) -> String {
        let normalizedFeedURL = URL(string: feedURL).map {
            $0.podcastFeedComparisonKeys.sorted().first
                ?? PodcastFeedIdentity.normalizedFeedURLString($0)
        } ?? feedURL
        return StableIdentityKey.make(
            normalizedFeedURL,
            episodeID,
            String(Int(startedAt.timeIntervalSince1970.rounded())),
            String(Int(endedAt.timeIntervalSince1970.rounded())),
            String(Int((startPosition * 10).rounded())),
            String(Int((endPosition * 10).rounded()))
        )
    }

    static func make(for record: ListeningHistorySync) -> String {
        make(
            feedURL: record.feedURL,
            episodeID: record.episodeID,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            startPosition: record.startPosition,
            endPosition: record.endPosition
        )
    }
}

enum ListeningHistoryAggregation {
    static func deduplicated(
        _ records: [ListeningHistorySync],
        sourceDeviceID: String? = nil
    ) -> [ListeningHistorySync] {
        var newestByIdentity: [String: ListeningHistorySync] = [:]

        for record in records {
            guard sourceDeviceID == nil || record.sourceDeviceID == sourceDeviceID else {
                continue
            }
            let identity = ListeningHistoryIdentity.make(for: record)
            if let existing = newestByIdentity[identity],
               !prefers(record, over: existing) {
                continue
            }
            newestByIdentity[identity] = record
        }

        return newestByIdentity.values.sorted {
            if $0.startedAt != $1.startedAt {
                return $0.startedAt > $1.startedAt
            }
            return $0.id < $1.id
        }
    }

    static func globalStatistics(
        from records: [ListeningHistorySync],
        sourceDeviceID: String? = nil
    ) -> GlobalListeningStatistics {
        deduplicated(records, sourceDeviceID: sourceDeviceID).reduce(
            into: GlobalListeningStatistics(
                totalSeconds: 0,
                silenceGapTimeSavedSeconds: 0,
                playbackRateTimeSavedSeconds: 0,
                sessionCount: 0
            )
        ) { result, record in
            result.totalSeconds += max(0, record.listenedSeconds)
            result.silenceGapTimeSavedSeconds += max(0, record.silenceGapTimeSavedSeconds)
            result.playbackRateTimeSavedSeconds += max(0, record.playbackRateTimeSavedSeconds)
            result.sessionCount += 1
        }
    }

    private static func prefers(
        _ candidate: ListeningHistorySync,
        over existing: ListeningHistorySync
    ) -> Bool {
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        if candidate.endedAt != existing.endedAt {
            return candidate.endedAt > existing.endedAt
        }
        if candidate.listenedSeconds != existing.listenedSeconds {
            return candidate.listenedSeconds > existing.listenedSeconds
        }
        return candidate.sourceDeviceID < existing.sourceDeviceID
    }
}

enum ListeningSummaryAggregation {
    static func globalStatistics(
        from records: [ListeningSummarySync],
        sourceDeviceID: String? = nil
    ) -> GlobalListeningStatistics {
        struct Contribution {
            var totalSeconds: Double
            var silenceGapTimeSavedSeconds: Double
            var playbackRateTimeSavedSeconds: Double
        }

        var contributionsByID: [String: Contribution] = [:]

        for record in records {
            guard sourceDeviceID == nil || record.sourceDeviceID == sourceDeviceID else {
                continue
            }
            let existing = contributionsByID[record.id]
            contributionsByID[record.id] = Contribution(
                totalSeconds: max(existing?.totalSeconds ?? 0, record.totalSeconds),
                silenceGapTimeSavedSeconds: max(
                    existing?.silenceGapTimeSavedSeconds ?? 0,
                    record.silenceGapTimeSavedSeconds
                ),
                playbackRateTimeSavedSeconds: max(
                    existing?.playbackRateTimeSavedSeconds ?? 0,
                    record.playbackRateTimeSavedSeconds
                )
            )
        }

        return contributionsByID.values.reduce(
            into: GlobalListeningStatistics(
                totalSeconds: 0,
                silenceGapTimeSavedSeconds: 0,
                playbackRateTimeSavedSeconds: 0,
                sessionCount: 0
            )
        ) { result, contribution in
            result.totalSeconds += max(0, contribution.totalSeconds)
            result.silenceGapTimeSavedSeconds += max(0, contribution.silenceGapTimeSavedSeconds)
            result.playbackRateTimeSavedSeconds += max(0, contribution.playbackRateTimeSavedSeconds)
        }
    }
}
