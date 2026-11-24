import Foundation

extension Notification.Name {
    static let episodeDownloadStarted = Notification.Name("episodeDownloadStarted")
    static let episodeDownloadFinished = Notification.Name("episodeDownloadFinished")
    static let episodeChapterExtractionFinished = Notification.Name("episodeChapterExtractionFinished")
}

enum EpisodeDownloadNotificationKey {
    static let episodeURL = "episodeURL"
}

enum EpisodeChapterExtractionNotificationKey {
    static let episodeURL = "episodeURL"
    static let didChange = "didChange"
    static let chapterCount = "chapterCount"
}
