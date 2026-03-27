import Foundation
import SwiftData

@Model
final class TranscriptionRecord {
    var id: UUID = UUID()
    var episodeURL: URL?
    var episodeTitle: String = ""
    var podcastTitle: String?
    var localeIdentifier: String = Locale.current.identifier
    var startedAt: Date = Date()
    var finishedAt: Date = Date()
    var audioDuration: Double = 0
    var transcriptionDuration: Double = 0

    init(
        episodeURL: URL,
        episodeTitle: String,
        podcastTitle: String?,
        localeIdentifier: String,
        startedAt: Date,
        finishedAt: Date,
        audioDuration: Double
    ) {
        self.episodeURL = episodeURL
        self.episodeTitle = episodeTitle
        self.podcastTitle = podcastTitle
        self.localeIdentifier = localeIdentifier
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.audioDuration = audioDuration
        self.transcriptionDuration = finishedAt.timeIntervalSince(startedAt)
    }

    var speedRelativeToRealtime: Double {
        guard transcriptionDuration > 0 else { return 0 }
        return audioDuration / transcriptionDuration
    }

    var processingShareOfEpisodeDuration: Double {
        guard audioDuration > 0 else { return 0 }
        return transcriptionDuration / audioDuration
    }
}
