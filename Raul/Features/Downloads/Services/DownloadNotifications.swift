import Foundation

extension Notification.Name {
    static let episodeDownloadStarted = Notification.Name("episodeDownloadStarted")
    static let episodeDownloadFinished = Notification.Name("episodeDownloadFinished")
}

enum EpisodeDownloadNotificationKey {
    static let episodeURL = "episodeURL"
}
