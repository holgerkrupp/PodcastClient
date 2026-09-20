import Foundation

struct SharedEpisodePlaylistSnapshot: Codable, Hashable, Identifiable {
    let id: UUID
    let title: String
    let symbolName: String
}

struct PendingSharedEpisodeRequest: Codable, Hashable, Identifiable {
    let id: UUID
    let url: URL
    let playlistID: UUID?

    init(id: UUID = UUID(), url: URL, playlistID: UUID?) {
        self.id = id
        self.url = url
        self.playlistID = playlistID
    }
}

enum PendingSharedEpisodeShareStore {
    private static let appGroupID = "group.de.holgerkrupp.PodcastClient"
    private static let pendingRequestsKey = "PendingSharedEpisodeRequests"
    private static let playlistSnapshotKey = "SharedEpisodePlaylistSnapshot"

    static func playlists() -> [SharedEpisodePlaylistSnapshot] {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: playlistSnapshotKey),
              let playlists = try? JSONDecoder().decode(
                [SharedEpisodePlaylistSnapshot].self,
                from: data
              ) else {
            return []
        }

        return playlists
    }

    static func save(_ url: URL, playlistID: UUID?) throws {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            throw ShareExtensionError.appGroupUnavailable
        }

        var requests: [PendingSharedEpisodeRequest] = []
        if let data = defaults.data(forKey: pendingRequestsKey) {
            requests = (try? JSONDecoder().decode(
                [PendingSharedEpisodeRequest].self,
                from: data
            )) ?? []
        }

        // Re-sharing the same page to the same destination before the app next
        // becomes active should not create duplicate work.
        if requests.contains(where: {
            $0.url == url && $0.playlistID == playlistID
        }) == false {
            requests.append(
                PendingSharedEpisodeRequest(url: url, playlistID: playlistID)
            )
        }

        defaults.set(try JSONEncoder().encode(requests), forKey: pendingRequestsKey)
    }
}
