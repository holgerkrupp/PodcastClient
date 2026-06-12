import Foundation

enum PendingSharedEpisodeShareStore {
    private static let appGroupID = "group.de.holgerkrupp.PodcastClient"
    private static let pendingURLKey = "PendingSharedEpisodeURL"

    static func save(_ url: URL) throws {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            throw ShareExtensionError.appGroupUnavailable
        }

        defaults.set(url.absoluteString, forKey: pendingURLKey)
    }
}
