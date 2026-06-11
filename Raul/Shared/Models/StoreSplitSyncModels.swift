import Foundation
import SwiftData

@Model
final class SubscriptionSync: Identifiable {
    var id: String
    var feedURL: String
    var titleOverride: String?
    var displaySettingsRawValue: String?
    var subscribedAt: Date
    var updatedAt: Date

    init(
        feedURL: String,
        titleOverride: String? = nil,
        displaySettingsRawValue: String? = nil,
        subscribedAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = feedURL
        self.feedURL = feedURL
        self.titleOverride = titleOverride
        self.displaySettingsRawValue = displaySettingsRawValue
        self.subscribedAt = subscribedAt
        self.updatedAt = updatedAt
    }
}

@Model
final class EpisodeStateSync: Identifiable {
    var id: String
    var feedURL: String
    var episodeID: String
    var playPosition: Double = 0
    var duration: Double?
    var isPlayed: Bool = false
    var isArchived: Bool = false
    var isFavorite: Bool = false
    var lastPlayedAt: Date?
    var updatedAt: Date
    var sourceDeviceID: String?

    init(
        feedURL: String,
        episodeID: String,
        playPosition: Double = 0,
        duration: Double? = nil,
        isPlayed: Bool = false,
        isArchived: Bool = false,
        isFavorite: Bool = false,
        lastPlayedAt: Date? = nil,
        updatedAt: Date = .now,
        sourceDeviceID: String? = nil
    ) {
        self.id = "\(feedURL)|\(episodeID)"
        self.feedURL = feedURL
        self.episodeID = episodeID
        self.playPosition = playPosition
        self.duration = duration
        self.isPlayed = isPlayed
        self.isArchived = isArchived
        self.isFavorite = isFavorite
        self.lastPlayedAt = lastPlayedAt
        self.updatedAt = updatedAt
        self.sourceDeviceID = sourceDeviceID
    }
}

@Model
final class QueueEntrySync: Identifiable {
    var id: String
    var feedURL: String
    var episodeID: String
    var sortIndex: Int
    var addedAt: Date
    var updatedAt: Date

    init(
        feedURL: String,
        episodeID: String,
        sortIndex: Int,
        addedAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = "\(feedURL)|\(episodeID)"
        self.feedURL = feedURL
        self.episodeID = episodeID
        self.sortIndex = sortIndex
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }
}

@Model
final class BookmarkSync: Identifiable {
    var id: String
    var feedURL: String
    var episodeID: String
    var time: Double
    var title: String?
    var note: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        feedURL: String,
        episodeID: String,
        time: Double,
        title: String? = nil,
        note: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        let normalizedTime = Int((time * 10).rounded())
        self.id = "\(feedURL)|\(episodeID)|\(normalizedTime)|\(Int(createdAt.timeIntervalSince1970))"
        self.feedURL = feedURL
        self.episodeID = episodeID
        self.time = time
        self.title = title
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class ListeningSummarySync: Identifiable {
    var id: String
    var feedURL: String
    var periodKind: String
    var periodStart: Date
    var sourceDeviceID: String?
    var podcastName: String?
    var totalSeconds: Double = 0
    var silenceGapTimeSavedSeconds: Double = 0
    var playbackRateTimeSavedSeconds: Double = 0
    var activeHourCount: Int = 0
    var updatedAt: Date

    init(
        feedURL: String,
        periodKind: String,
        periodStart: Date,
        sourceDeviceID: String? = nil,
        podcastName: String? = nil,
        totalSeconds: Double = 0,
        silenceGapTimeSavedSeconds: Double = 0,
        playbackRateTimeSavedSeconds: Double = 0,
        activeHourCount: Int = 0,
        updatedAt: Date = .now
    ) {
        self.id = [
            feedURL,
            periodKind,
            String(Int(periodStart.timeIntervalSince1970)),
            sourceDeviceID ?? "__unknown_device__"
        ].joined(separator: "|")
        self.feedURL = feedURL
        self.periodKind = periodKind
        self.periodStart = periodStart
        self.sourceDeviceID = sourceDeviceID
        self.podcastName = podcastName
        self.totalSeconds = totalSeconds
        self.silenceGapTimeSavedSeconds = silenceGapTimeSavedSeconds
        self.playbackRateTimeSavedSeconds = playbackRateTimeSavedSeconds
        self.activeHourCount = activeHourCount
        self.updatedAt = updatedAt
    }

    var aggregationKey: String {
        [
            feedURL,
            periodKind,
            String(Int(periodStart.timeIntervalSince1970))
        ].joined(separator: "|")
    }
}
