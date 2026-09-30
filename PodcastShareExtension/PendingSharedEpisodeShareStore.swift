import Foundation

struct SharedEpisodePlaylistSnapshot: Codable, Hashable, Identifiable {
    let id: UUID
    let title: String
    let symbolName: String
}

enum PendingSharedEpisodeActionKind: String, Codable, Sendable {
    case importEpisode
    case subscribe
    case search
}

struct PendingSharedEpisodeAction: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let kind: PendingSharedEpisodeActionKind
    let url: URL
    let feedURL: URL?
    let query: String?
    let playlistID: UUID?

    static func importEpisode(url: URL, playlistID: UUID?) -> Self {
        Self(id: UUID(), kind: .importEpisode, url: url, feedURL: nil, query: nil, playlistID: playlistID)
    }

    static func subscribe(feedURL: URL, sharedURL: URL) -> Self {
        Self(id: UUID(), kind: .subscribe, url: sharedURL, feedURL: feedURL, query: nil, playlistID: nil)
    }

    static func search(query: String, sharedURL: URL) -> Self {
        Self(id: UUID(), kind: .search, url: sharedURL, feedURL: nil, query: query, playlistID: nil)
    }
}

private struct PendingSharedEpisodeActionEnvelope: Codable {
    let version: Int
    let actions: [PendingSharedEpisodeAction]
}

private struct LegacyPendingSharedEpisodeRequest: Codable {
    let id: UUID
    let url: URL
    let playlistID: UUID?
}

enum PendingSharedEpisodeShareStore {
    private static let appGroupID = "group.de.holgerkrupp.PodcastClient"
    private static let pendingRequestsKey = "PendingSharedEpisodeRequests"
    private static let playlistSnapshotKey = "SharedEpisodePlaylistSnapshot"

    static func playlists() -> [SharedEpisodePlaylistSnapshot] {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: playlistSnapshotKey),
              let playlists = try? JSONDecoder().decode([SharedEpisodePlaylistSnapshot].self, from: data) else {
            return []
        }
        return playlists
    }

    static func save(_ action: PendingSharedEpisodeAction) throws {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            throw ShareExtensionError.appGroupUnavailable
        }

        var actions = actions(in: defaults)
        guard actions.contains(where: { equivalent($0, action) }) == false else { return }
        actions.append(action)
        let envelope = PendingSharedEpisodeActionEnvelope(version: 2, actions: actions)
        defaults.set(try JSONEncoder().encode(envelope), forKey: pendingRequestsKey)
    }

    private static func actions(in defaults: UserDefaults) -> [PendingSharedEpisodeAction] {
        guard let data = defaults.data(forKey: pendingRequestsKey) else { return [] }
        if let envelope = try? JSONDecoder().decode(PendingSharedEpisodeActionEnvelope.self, from: data) {
            return envelope.actions
        }
        guard let legacy = try? JSONDecoder().decode([LegacyPendingSharedEpisodeRequest].self, from: data) else { return [] }
        return legacy.map { PendingSharedEpisodeAction(id: $0.id, kind: .importEpisode, url: $0.url, feedURL: nil, query: nil, playlistID: $0.playlistID) }
    }

    private static func equivalent(_ lhs: PendingSharedEpisodeAction, _ rhs: PendingSharedEpisodeAction) -> Bool {
        lhs.kind == rhs.kind && lhs.url == rhs.url && lhs.feedURL == rhs.feedURL && lhs.query == rhs.query && lhs.playlistID == rhs.playlistID
    }
}
