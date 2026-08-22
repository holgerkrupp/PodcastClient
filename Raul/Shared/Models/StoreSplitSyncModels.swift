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

/// Portable playback and presentation preferences. Device policy such as
/// downloads, network selection, transcription capability, voices, diagnostics,
/// and the currently selected playlist deliberately stay out of this record.
/// A row is either global (`feedURL == nil`) or scoped to one normalized feed.
@Model
final class PodcastPreferenceSync: Identifiable {
    var id: String = ""
    var feedURL: String?
    var isEnabled: Bool = true
    var playNextPositionRawValue: String = ""
    var defaultPlaylistID: String?
    var playbackSpeed: Double?
    var reduceSilenceGapsEnabled: Bool = false
    var silenceGapReductionLevelRawValue: String?
    var voiceEnhancementEnabled: Bool = false
    var autoSkipKeywordsJSON: String = "[]"
    var cutFront: Double?
    var cutEnd: Double?
    var skipForwardSeconds: Int = 30
    var skipBackSeconds: Int = 15
    var skipForwardBehaviorRawValue: String?
    var skipBackBehaviorRawValue: String?
    var markAsPlayedAfterSubscribe: Bool = true
    var playSumAdjustedByPlaySpeed: Bool = false
    var enableLockscreenSlider: Bool = true
    var enableInAppSlider: Bool = true
    var continuousPlayEnabled: Bool = true
    var liveItemNotificationsEnabled: Bool = true
    var sleepTimerAddMinutes: Double = 10
    var sleepTimerDurationToReactivate: Double = 300
    var sleepTimerVoiceFeedbackEnabled: Bool = true
    var sleepTimerText: String = "Sleep Timer extended"
    var updatedAt: Date = Date.distantPast
    var sourceDeviceID: String?

    init(
        feedURL: String?,
        isEnabled: Bool = true,
        playNextPositionRawValue: String = "",
        defaultPlaylistID: String? = nil,
        playbackSpeed: Double? = nil,
        reduceSilenceGapsEnabled: Bool = false,
        silenceGapReductionLevelRawValue: String? = nil,
        voiceEnhancementEnabled: Bool = false,
        autoSkipKeywordsJSON: String = "[]",
        cutFront: Double? = nil,
        cutEnd: Double? = nil,
        skipForwardSeconds: Int = 30,
        skipBackSeconds: Int = 15,
        skipForwardBehaviorRawValue: String? = nil,
        skipBackBehaviorRawValue: String? = nil,
        markAsPlayedAfterSubscribe: Bool = true,
        playSumAdjustedByPlaySpeed: Bool = false,
        enableLockscreenSlider: Bool = true,
        enableInAppSlider: Bool = true,
        continuousPlayEnabled: Bool = true,
        liveItemNotificationsEnabled: Bool = true,
        sleepTimerAddMinutes: Double = 10,
        sleepTimerDurationToReactivate: Double = 300,
        sleepTimerVoiceFeedbackEnabled: Bool = true,
        sleepTimerText: String = "Sleep Timer extended",
        updatedAt: Date = .now,
        sourceDeviceID: String? = nil
    ) {
        self.id = feedURL.map { StableIdentityKey.make("feed", $0) }
            ?? StableIdentityKey.make("global")
        self.feedURL = feedURL
        self.isEnabled = isEnabled
        self.playNextPositionRawValue = playNextPositionRawValue
        self.defaultPlaylistID = defaultPlaylistID
        self.playbackSpeed = playbackSpeed
        self.reduceSilenceGapsEnabled = reduceSilenceGapsEnabled
        self.silenceGapReductionLevelRawValue = silenceGapReductionLevelRawValue
        self.voiceEnhancementEnabled = voiceEnhancementEnabled
        self.autoSkipKeywordsJSON = autoSkipKeywordsJSON
        self.cutFront = cutFront
        self.cutEnd = cutEnd
        self.skipForwardSeconds = skipForwardSeconds
        self.skipBackSeconds = skipBackSeconds
        self.skipForwardBehaviorRawValue = skipForwardBehaviorRawValue
        self.skipBackBehaviorRawValue = skipBackBehaviorRawValue
        self.markAsPlayedAfterSubscribe = markAsPlayedAfterSubscribe
        self.playSumAdjustedByPlaySpeed = playSumAdjustedByPlaySpeed
        self.enableLockscreenSlider = enableLockscreenSlider
        self.enableInAppSlider = enableInAppSlider
        self.continuousPlayEnabled = continuousPlayEnabled
        self.liveItemNotificationsEnabled = liveItemNotificationsEnabled
        self.sleepTimerAddMinutes = sleepTimerAddMinutes
        self.sleepTimerDurationToReactivate = sleepTimerDurationToReactivate
        self.sleepTimerVoiceFeedbackEnabled = sleepTimerVoiceFeedbackEnabled
        self.sleepTimerText = sleepTimerText
        self.updatedAt = updatedAt
        self.sourceDeviceID = sourceDeviceID
    }
}

/// The one number the split cannot recompute: how much listening happened before
/// this account migrated.
///
/// Raw `PlaySession` rows are pruned after 30 days
/// (`PlaySessionTrackerActor.rawSessionRetentionDays`), so the pre-split era
/// survives only as legacy aggregates. One row per feed captures it, written once
/// at migration and never touched again — not republished, not merged, not
/// recomputed. That is what keeps it from becoming an input to its own
/// derivation, which is how per-period, per-device rollups turned one device's
/// wrong total into the account's permanent one.
///
/// Everything after the capture is derived locally from `ListeningHistorySync`,
/// so this record is a constant rather than a running total. It is also the
/// reason `ListeningHistorySync.isLegacyMigrated` still matters: migrated session
/// rows are already inside this number and must never be added to it.
@Model
final class ListeningBaselineSync: Identifiable {
    /// The normalized feed this baseline covers, or `__all_podcasts__`.
    var id: String = ""
    var feedURL: String = ""
    var podcastName: String?
    var totalSeconds: Double = 0
    var silenceGapTimeSavedSeconds: Double = 0
    var playbackRateTimeSavedSeconds: Double = 0
    /// Which device captured the snapshot, and when. Both are for support and
    /// display only; neither takes part in any total.
    var capturedAt: Date = Date.distantPast
    var capturedByDeviceID: String?

    init(
        feedURL: String,
        podcastName: String? = nil,
        totalSeconds: Double,
        silenceGapTimeSavedSeconds: Double = 0,
        playbackRateTimeSavedSeconds: Double = 0,
        capturedAt: Date = .now,
        capturedByDeviceID: String? = nil
    ) {
        self.id = feedURL
        self.feedURL = feedURL
        self.podcastName = podcastName
        self.totalSeconds = totalSeconds
        self.silenceGapTimeSavedSeconds = silenceGapTimeSavedSeconds
        self.playbackRateTimeSavedSeconds = playbackRateTimeSavedSeconds
        self.capturedAt = capturedAt
        self.capturedByDeviceID = capturedByDeviceID
    }
}

extension ListeningBaselineSync {
    /// The feed key used for the account-wide baseline row.
    static let allPodcastsFeedURL = "__all_podcasts__"
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
    /// True only for rows copied from SharedDatabase during the store split.
    /// Live per-device summaries exclude these rows because the migrated
    /// `__legacy_shared__` summary already accounts for their contribution.
    var isLegacyMigrated: Bool = false
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
        isLegacyMigrated: Bool = false,
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
        self.isLegacyMigrated = isLegacyMigrated
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
    private static func normalizedFeedURL(_ feedURL: String) -> String {
        URL(string: feedURL).map {
            $0.podcastFeedComparisonKeys.sorted().first
                ?? PodcastFeedIdentity.normalizedFeedURLString($0)
        } ?? feedURL
    }

    static func make(
        feedURL: String,
        episodeID: String,
        startedAt: Date,
        endedAt: Date,
        startPosition: Double,
        endPosition: Double
    ) -> String {
        let normalizedFeedURL = normalizedFeedURL(feedURL)
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

    static func canonicalAggregationKey(
        feedURL: String,
        episodeID: String,
        startedAt: Date,
        endedAt: Date,
        listenedSeconds: Double
    ) -> String {
        StableIdentityKey.make(
            normalizedFeedURL(feedURL),
            episodeID,
            String(Int(startedAt.timeIntervalSince1970.rounded())),
            String(Int(endedAt.timeIntervalSince1970.rounded())),
            String(Int(listenedSeconds.rounded()))
        )
    }

    static func canonicalAggregationKey(for record: ListeningHistorySync) -> String {
        canonicalAggregationKey(
            feedURL: record.feedURL,
            episodeID: record.episodeID,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            listenedSeconds: record.listenedSeconds
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
            let identity = ListeningHistoryIdentity.canonicalAggregationKey(for: record)
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

struct DeviceListeningShare: Equatable, Sendable {
    let deviceID: String
    let seconds: Double
    /// Fraction of the account total, 0...1.
    let share: Double
}

/// The arithmetic behind per-account listening statistics.
///
/// It lives here rather than in the statistics view because it is the invariant
/// the synced schema is shaped around, not a presentation detail: the account
/// total is the frozen pre-split baseline plus the sessions recorded since, and
/// the per-device shares are the same sessions grouped by the device that
/// recorded them. One set of rows, two readings, so the total and the shares
/// cannot disagree.
enum AccountListeningTotals {
    /// Lifetime seconds for the account.
    ///
    /// `migratedSeconds` are the sessions the migration copied out of the legacy
    /// store. The baseline was computed from aggregates that already contain
    /// them, so they are counted only when this account has no baseline — on a
    /// device that installed after the split, they are the sole record of the
    /// pre-split era.
    static func lifetimeSeconds(
        baselineSeconds: Double?,
        liveSeconds: Double,
        migratedSeconds: Double
    ) -> Double {
        guard let baselineSeconds else {
            return max(0, liveSeconds) + max(0, migratedSeconds)
        }
        return max(0, baselineSeconds) + max(0, liveSeconds)
    }

    /// Per-device shares of one period's listening.
    ///
    /// The baseline predates device attribution, so when it is included it is
    /// attributed to `baselineDeviceID` — a pseudo-device the statistics view
    /// labels "Migrated history". Shares are computed against the sum of exactly
    /// the rows returned, so they always add to 1.
    static func deviceShares(
        secondsByDevice: [String: Double],
        baselineSeconds: Double? = nil,
        baselineDeviceID: String = ListeningDeviceIdentity.legacySharedID
    ) -> [DeviceListeningShare] {
        var totals = secondsByDevice.compactMapValues { $0 > 0 ? $0 : nil }
        if let baselineSeconds, baselineSeconds > 0 {
            totals[baselineDeviceID] = baselineSeconds
        }
        let total = totals.values.reduce(0, +)
        guard total > 0 else { return [] }
        return totals
            .map {
                DeviceListeningShare(
                    deviceID: $0.key,
                    seconds: $0.value,
                    share: $0.value / total
                )
            }
            .sorted {
                if $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
                return $0.deviceID < $1.deviceID
            }
    }
}
