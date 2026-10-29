import Foundation

/// Persistent cursors for the independently synchronized UserState streams.
///
enum StoreSplitUserStateStream: String, CaseIterable, Codable, Hashable, Sendable {
    case subscriptions
    case episodeState
    case playlists
    case playlistEntries
    case queueEntries
    case bookmarks
    case preferences
    case listeningHistory
    case listeningBaseline
}

struct StoreSplitImportCursor: Codable, Equatable, Sendable {
    var importedThrough: Date?
    var recordIDsAtTimestamp: [String]
}

struct StoreSplitUserStateChangeSnapshot: Equatable, Sendable {
    var date: Date?
    var recordIDsAtTimestamp: [String]
}

enum StoreSplitImportCursorStore {
    private static let key = "storeSplit.userStateImportCursors.v1"

    private static func defaults() -> UserDefaults {
        UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    }

    static func load(defaults suppliedDefaults: UserDefaults? = nil) -> [StoreSplitUserStateStream: StoreSplitImportCursor] {
        guard let data = (suppliedDefaults ?? defaults()).data(forKey: key),
              let raw = try? JSONDecoder().decode(
                  [String: StoreSplitImportCursor].self,
                  from: data
              ) else {
            return [:]
        }
        return raw.reduce(into: [:]) { result, entry in
            guard let stream = StoreSplitUserStateStream(rawValue: entry.key) else { return }
            result[stream] = entry.value
        }
    }

    static func save(_ cursors: [StoreSplitUserStateStream: StoreSplitImportCursor], defaults suppliedDefaults: UserDefaults? = nil) {
        let raw = Dictionary(uniqueKeysWithValues: cursors.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        (suppliedDefaults ?? defaults()).set(data, forKey: key)
    }

    static func changedStreams(
        current: [StoreSplitUserStateStream: StoreSplitUserStateChangeSnapshot],
        force: Bool,
        defaults suppliedDefaults: UserDefaults? = nil
    ) -> Set<StoreSplitUserStateStream> {
        if force { return Set(StoreSplitUserStateStream.allCases) }
        let cursors = load(defaults: suppliedDefaults)
        return Set(StoreSplitUserStateStream.allCases.filter { stream in
            guard let currentSnapshot = current[stream], currentSnapshot.date != nil else {
                return false
            }
            guard let cursor = cursors[stream] else { return true }
            return cursor.importedThrough != currentSnapshot.date
                || cursor.recordIDsAtTimestamp != currentSnapshot.recordIDsAtTimestamp
        })
    }

    /// Keep playlist membership streams eligible for another import while a
    /// synchronized entry still points at an episode this device cannot
    /// resolve. The membership record remains authoritative in UserState, so
    /// leaving its cursor behind is a durable retry marker without copying the
    /// record into a second local ledger.
    static func streamsEligibleForCommit(
        changedStreams: Set<StoreSplitUserStateStream>,
        hasUnresolvedPlaylistEpisodes: Bool
    ) -> Set<StoreSplitUserStateStream> {
        guard hasUnresolvedPlaylistEpisodes else { return changedStreams }
        return changedStreams.subtracting([.playlistEntries, .queueEntries])
    }

    static func commit(
        _ current: [StoreSplitUserStateStream: StoreSplitUserStateChangeSnapshot],
        streams: Set<StoreSplitUserStateStream>,
        defaults suppliedDefaults: UserDefaults? = nil
    ) {
        var cursors = load(defaults: suppliedDefaults)
        for stream in streams {
            guard let snapshot = current[stream], let date = snapshot.date else { continue }
            cursors[stream] = StoreSplitImportCursor(
                importedThrough: date,
                recordIDsAtTimestamp: snapshot.recordIDsAtTimestamp
            )
        }
        save(cursors, defaults: suppliedDefaults)
    }
}
