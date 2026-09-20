import Foundation

struct PendingSharedEpisodeImportRequest: Codable, Hashable, Identifiable {
    let id: UUID
    let url: URL
    let playlistID: UUID?
}

private struct SharedEpisodePlaylistSnapshot: Codable, Hashable {
    let id: UUID
    let title: String
    let symbolName: String
}

enum PendingSharedEpisodeImportStore {
    private static let appGroupID = "group.de.holgerkrupp.PodcastClient"
    private static let pendingRequestsKey = "PendingSharedEpisodeRequests"
    private static let legacyPendingURLKey = "PendingSharedEpisodeURL"
    private static let playlistSnapshotKey = "SharedEpisodePlaylistSnapshot"

    static func pendingRequests() -> [PendingSharedEpisodeImportRequest] {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            return []
        }

        migrateLegacyRequestIfNeeded(in: defaults)

        guard let data = defaults.data(forKey: pendingRequestsKey),
              let requests = try? JSONDecoder().decode(
                [PendingSharedEpisodeImportRequest].self,
                from: data
              ) else {
            return []
        }

        let validRequests = requests.filter { isSupportedSharedURL($0.url) }
        if validRequests != requests {
            save(validRequests, in: defaults)
        }
        return validRequests
    }

    static func remove(id: UUID) {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: pendingRequestsKey),
              var requests = try? JSONDecoder().decode(
                [PendingSharedEpisodeImportRequest].self,
                from: data
              ) else {
            return
        }

        requests.removeAll { $0.id == id }
        save(requests, in: defaults)
    }

    @MainActor
    static func publish(playlists: [Playlist]) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }

        let snapshots = Playlist.manualVisibleSorted(playlists).map {
            SharedEpisodePlaylistSnapshot(
                id: $0.id,
                title: $0.displayTitle,
                symbolName: $0.displaySymbolName
            )
        }
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        defaults.set(data, forKey: playlistSnapshotKey)
    }

    private static func migrateLegacyRequestIfNeeded(in defaults: UserDefaults) {
        guard let rawValue = defaults.string(forKey: legacyPendingURLKey) else {
            return
        }

        defer { defaults.removeObject(forKey: legacyPendingURLKey) }
        guard let url = URL(string: rawValue), isSupportedSharedURL(url) else {
            return
        }

        var requests: [PendingSharedEpisodeImportRequest] = []
        if let data = defaults.data(forKey: pendingRequestsKey) {
            requests = (try? JSONDecoder().decode(
                [PendingSharedEpisodeImportRequest].self,
                from: data
            )) ?? []
        }

        guard requests.contains(where: {
            $0.url == url && $0.playlistID == nil
        }) == false else {
            return
        }

        requests.append(
            PendingSharedEpisodeImportRequest(
                id: UUID(),
                url: url,
                playlistID: nil
            )
        )
        save(requests, in: defaults)
    }

    private static func save(
        _ requests: [PendingSharedEpisodeImportRequest],
        in defaults: UserDefaults
    ) {
        if requests.isEmpty {
            defaults.removeObject(forKey: pendingRequestsKey)
            return
        }

        guard let data = try? JSONEncoder().encode(requests) else { return }
        defaults.set(data, forKey: pendingRequestsKey)
    }

    private static func isSupportedSharedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "feed", "rss"].contains(scheme)
    }
}
