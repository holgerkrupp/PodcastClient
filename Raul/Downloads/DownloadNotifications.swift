import Foundation

extension Notification.Name {
    static let episodeDownloadFinished = Notification.Name("episodeDownloadFinished")
}

enum EpisodeDownloadNotificationKey {
    static let episodeURL = "episodeURL"
}
