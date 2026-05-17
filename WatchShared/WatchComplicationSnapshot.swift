import Foundation

struct WatchComplicationSnapshot: Codable, Sendable {
    let generatedAt: Date
    let selectedPlaylistTitle: String
    let currentEpisodeID: String?
    let currentTitle: String?
    let currentPodcast: String?
    let currentChapterTitle: String?
    let duration: Double?
    let playPosition: Double?
    let isPlaying: Bool
    let playlistTotalCount: Int
    let currentIndex: Int?
    let nextTitle: String?
    let nextPodcast: String?
    let inboxCount: Int
    let downloadedCount: Int
    let activeTransferCount: Int
    let highestTransferProgress: Double?

    static let empty = WatchComplicationSnapshot(
        generatedAt: .distantPast,
        selectedPlaylistTitle: WatchSyncPlaylist.defaultQueue.title,
        currentEpisodeID: nil,
        currentTitle: nil,
        currentPodcast: nil,
        currentChapterTitle: nil,
        duration: nil,
        playPosition: nil,
        isPlaying: false,
        playlistTotalCount: 0,
        currentIndex: nil,
        nextTitle: nil,
        nextPodcast: nil,
        inboxCount: 0,
        downloadedCount: 0,
        activeTransferCount: 0,
        highestTransferProgress: nil
    )

    var playbackProgress: Double? {
        guard let playPosition, let duration, duration > 0 else { return nil }
        return min(max(playPosition / duration, 0), 1)
    }

    var remainingCount: Int {
        guard playlistTotalCount > 0 else { return 0 }
        guard let currentIndex else { return playlistTotalCount }
        return max(playlistTotalCount - currentIndex - 1, 0)
    }
}

enum WatchComplicationStore {
    static let appGroupID = "group.de.holgerkrupp.PodcastClient"
    static let defaultsKey = "watch.complication.snapshot"

    static func load() -> WatchComplicationSnapshot {
        guard
            let defaults = UserDefaults(suiteName: appGroupID),
            let data = defaults.data(forKey: defaultsKey),
            let snapshot = WatchSyncTransport.decode(WatchComplicationSnapshot.self, from: data)
        else {
            return .empty
        }

        return snapshot
    }

    static func save(_ snapshot: WatchComplicationSnapshot) {
        guard
            let defaults = UserDefaults(suiteName: appGroupID),
            let data = WatchSyncTransport.encode(snapshot)
        else {
            return
        }

        defaults.set(data, forKey: defaultsKey)
    }
}
