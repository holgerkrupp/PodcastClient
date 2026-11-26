import Foundation

/// What a settings row's chosen auto-add playlist means on this device.
enum PodcastPlaylistTargetStatus: Equatable, Sendable {
    /// No playlist was chosen; the row inherits the global target.
    case notSet
    /// The chosen playlist exists here and can receive new episodes.
    case available(UUID)
    /// Chosen on another device; the playlist has not reached this one yet.
    case pending(syncID: String)
    /// The chosen playlist is here but hidden, deleted, or a smart playlist.
    case unavailable(UUID, title: String?)

    var isUnresolvedChoice: Bool {
        switch self {
        case .pending, .unavailable: true
        case .notSet, .available: false
        }
    }
}

/// The one policy for where automatically added episodes go, shared by the
/// settings picker, new-episode routing and auto-download.
///
/// A stored choice that cannot be used right now routes to the built-in
/// queue, but the choice itself is never rewritten here: only the user (or a
/// newer synchronized preference) changes it, so it resolves by itself once
/// the playlist arrives.
enum PodcastPlaylistTargetResolver {
    /// The local playlist a synchronized target identity names.
    ///
    /// Matches the playlist's stable sync identity first and otherwise only a
    /// playlist whose local UUID is exactly that value (legacy UUID-only
    /// preferences). A foreign UUID never becomes a local target by itself.
    static func matchingPlaylist(syncID: String, in playlists: [Playlist]) -> Playlist? {
        let trimmed = syncID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if let playlist = playlists.first(where: { $0.storeSplitSyncID == trimmed }) {
            return playlist
        }
        guard let uuid = UUID(uuidString: trimmed) else { return nil }
        return playlists.first { $0.id == uuid }
    }

    static func status(for settings: PodcastSettings, playlists: [Playlist]) -> PodcastPlaylistTargetStatus {
        let playlist: Playlist?
        if let syncID = settings.defaultPlaylistSyncID {
            playlist = matchingPlaylist(syncID: syncID, in: playlists)
            if playlist == nil { return .pending(syncID: syncID) }
        } else if let playlistID = settings.defaultPlaylistID {
            playlist = playlists.first { $0.id == playlistID }
            if playlist == nil { return .unavailable(playlistID, title: nil) }
        } else {
            return .notSet
        }
        guard let playlist else { return .notSet }
        guard playlist.hidden == false, playlist.isSmartPlaylist == false else {
            return .unavailable(playlist.id, title: playlist.displayTitle)
        }
        return .available(playlist.id)
    }

    /// Where new episodes for these settings are added.
    ///
    /// - Parameters:
    ///   - settings: The podcast's enabled custom settings, if any.
    ///   - global: The app-wide settings.
    static func routingPlaylistID(
        settings: PodcastSettings?,
        global: PodcastSettings?,
        playlists: [Playlist],
        defaultQueueID: UUID
    ) -> UUID {
        if let settings {
            switch status(for: settings, playlists: playlists) {
            case .available(let id): return id
            case .pending, .unavailable: return defaultQueueID
            case .notSet: break
            }
        }
        if let global, case .available(let id) = status(for: global, playlists: playlists) {
            return id
        }
        return defaultQueueID
    }

    /// Whether the settings row carries its own playlist choice.
    static func hasOwnTarget(_ settings: PodcastSettings?) -> Bool {
        settings?.defaultPlaylistSyncID != nil || settings?.defaultPlaylistID != nil
    }
}

extension PodcastSettings {
    /// Records a user's playlist choice: both the local UUID and the identity
    /// other devices know the playlist by.
    func chooseDefaultPlaylist(_ playlist: Playlist?) {
        defaultPlaylistID = playlist?.id
        defaultPlaylistSyncID = playlist?.storeSplitSyncID
    }
}
