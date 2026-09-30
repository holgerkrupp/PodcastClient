import Foundation

struct PendingSharedEpisodeImportRequest: Codable, Hashable, Identifiable {
    let id: UUID
    let url: URL
    let playlistID: UUID?
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

private struct LegacyPendingSharedEpisodeRequest: Codable, Hashable {
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

    static func pendingActions() -> [PendingSharedEpisodeAction] {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return [] }
        migrateLegacyRequestIfNeeded(in: defaults)
        guard let data = defaults.data(forKey: pendingRequestsKey) else { return [] }

        if let envelope = try? JSONDecoder().decode(PendingSharedEpisodeActionEnvelope.self, from: data) {
            return envelope.actions.filter { isSupportedSharedURL($0.url) }
        }

        guard let legacy = try? JSONDecoder().decode([LegacyPendingSharedEpisodeRequest].self, from: data) else { return [] }
        let actions = legacy
            .filter { isSupportedSharedURL($0.url) }
            .map { PendingSharedEpisodeAction(id: $0.id, kind: .importEpisode, url: $0.url, feedURL: nil, query: nil, playlistID: $0.playlistID) }
        save(actions, in: defaults)
        return actions
    }

    static func pendingRequests() -> [PendingSharedEpisodeImportRequest] {
        pendingActions().compactMap { action in
            guard action.kind == .importEpisode else { return nil }
            return PendingSharedEpisodeImportRequest(id: action.id, url: action.url, playlistID: action.playlistID)
        }
    }

    static func save(_ action: PendingSharedEpisodeAction) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        var actions = pendingActions()
        guard actions.contains(where: { equivalent($0, action) }) == false else { return }
        actions.append(action)
        save(actions, in: defaults)
    }

    static func remove(id: UUID) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        save(pendingActions().filter { $0.id != id }, in: defaults)
    }

    @MainActor
    static func publish(playlists: [Playlist]) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        let snapshots = Playlist.manualVisibleSorted(playlists).map {
            SharedEpisodePlaylistSnapshot(id: $0.id, title: $0.displayTitle, symbolName: $0.displaySymbolName)
        }
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        defaults.set(data, forKey: playlistSnapshotKey)
    }

    private static func migrateLegacyRequestIfNeeded(in defaults: UserDefaults) {
        guard let rawValue = defaults.string(forKey: legacyPendingURLKey),
              let url = URL(string: rawValue), isSupportedSharedURL(url) else {
            defaults.removeObject(forKey: legacyPendingURLKey)
            return
        }
        defer { defaults.removeObject(forKey: legacyPendingURLKey) }

        var actions = pendingActionsFromStorage(in: defaults)
        guard actions.contains(where: { $0.url == url && $0.kind == .importEpisode && $0.playlistID == nil }) == false else { return }
        actions.append(.importEpisode(url: url, playlistID: nil))
        save(actions, in: defaults)
    }

    private static func pendingActionsFromStorage(in defaults: UserDefaults) -> [PendingSharedEpisodeAction] {
        guard let data = defaults.data(forKey: pendingRequestsKey) else { return [] }
        if let envelope = try? JSONDecoder().decode(PendingSharedEpisodeActionEnvelope.self, from: data) {
            return envelope.actions
        }
        guard let legacy = try? JSONDecoder().decode([LegacyPendingSharedEpisodeRequest].self, from: data) else { return [] }
        return legacy.map { PendingSharedEpisodeAction(id: $0.id, kind: .importEpisode, url: $0.url, feedURL: nil, query: nil, playlistID: $0.playlistID) }
    }

    private static func save(_ actions: [PendingSharedEpisodeAction], in defaults: UserDefaults) {
        if actions.isEmpty {
            defaults.removeObject(forKey: pendingRequestsKey)
            return
        }
        let envelope = PendingSharedEpisodeActionEnvelope(version: 2, actions: actions)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        defaults.set(data, forKey: pendingRequestsKey)
    }

    private static func equivalent(_ lhs: PendingSharedEpisodeAction, _ rhs: PendingSharedEpisodeAction) -> Bool {
        lhs.kind == rhs.kind && lhs.url == rhs.url && lhs.feedURL == rhs.feedURL && lhs.query == rhs.query && lhs.playlistID == rhs.playlistID
    }

    private static func isSupportedSharedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "feed", "rss"].contains(scheme)
    }
}
