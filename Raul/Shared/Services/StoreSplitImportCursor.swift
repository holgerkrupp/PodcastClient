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

/// Records at or before `importedThrough` have been projected, except that a
/// record stamped exactly `importedThrough` counts only when its ID is listed
/// in `recordIDsAtTimestamp`. A later arrival that shares the boundary
/// timestamp is therefore still imported.
struct StoreSplitImportCursor: Codable, Equatable, Sendable {
    var importedThrough: Date?
    var recordIDsAtTimestamp: [String]
    /// When the importer last walked the whole stream instead of only the rows
    /// after the cursor. CloudKit can deliver a record authored long ago (a
    /// device that was offline), which a timestamp cursor cannot see; the
    /// periodic full pass is the backstop for those.
    var fullPassCompletedAt: Date? = nil
    /// A full pass saved some batches and was interrupted; the next pass
    /// resumes from the cursor and still counts as completing it.
    var fullPassInProgress: Bool? = nil
}

struct StoreSplitUserStateChangeSnapshot: Equatable, Sendable {
    var date: Date?
    var recordIDsAtTimestamp: [String]
}

enum StoreSplitImportCursorStore {
    private static let key = "storeSplit.userStateImportCursors.v1"
    /// A cursor boundary lists every record at its timestamp. Beyond this the
    /// list is not worth persisting; the previous cursor stays in place.
    static let maximumBoundaryRecordIDs = 500
    /// How long an incremental stream may go without a full pass.
    static let fullPassInterval: TimeInterval = 7 * 24 * 60 * 60

    private static func defaults() -> UserDefaults {
        UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    }

    /// Defaults suite the importer reads its starting cursors from and
    /// advances after each durably saved batch (the app group, the same suite
    /// `commit` writes).
    ///
    /// Unit tests that drive the importer without opting in get `nil`: no
    /// persisted cursor is read or written, so one test's progress can never
    /// hide another test's fixtures. Tests that exercise the cursor pass their
    /// own suite explicitly.
    static var importerSuiteName: String? {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return nil
        }
        return ModelContainerManager.appGroupID
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
                recordIDsAtTimestamp: snapshot.recordIDsAtTimestamp,
                fullPassCompletedAt: cursors[stream]?.fullPassCompletedAt,
                fullPassInProgress: cursors[stream]?.fullPassInProgress
            )
        }
        save(cursors, defaults: suppliedDefaults)
    }

    /// Moves one stream's cursor forward after a batch has been saved to the
    /// library. Never moves it backwards: a narrower or older batch cannot
    /// undo progress another pass already made durable.
    static func advance(
        _ stream: StoreSplitUserStateStream,
        through date: Date,
        recordIDsAtTimestamp ids: Set<String>,
        duringFullPass: Bool = false,
        defaults: UserDefaults
    ) {
        var cursors = load(defaults: defaults)
        let existing = cursors[stream]
        var boundaryIDs = ids
        if let importedThrough = existing?.importedThrough {
            if importedThrough > date { return }
            if importedThrough == date {
                boundaryIDs.formUnion(existing?.recordIDsAtTimestamp ?? [])
            }
        }
        guard boundaryIDs.count <= maximumBoundaryRecordIDs else { return }
        let updated = StoreSplitImportCursor(
            importedThrough: date,
            recordIDsAtTimestamp: boundaryIDs.sorted(),
            fullPassCompletedAt: existing?.fullPassCompletedAt,
            fullPassInProgress: duringFullPass ? true : existing?.fullPassInProgress
        )
        guard updated != existing else { return }
        cursors[stream] = updated
        save(cursors, defaults: defaults)
    }

    static func markFullPassCompleted(
        _ stream: StoreSplitUserStateStream,
        at date: Date = .now,
        defaults: UserDefaults
    ) {
        var cursors = load(defaults: defaults)
        var cursor = cursors[stream]
            ?? StoreSplitImportCursor(importedThrough: nil, recordIDsAtTimestamp: [])
        cursor.fullPassCompletedAt = date
        cursor.fullPassInProgress = nil
        cursors[stream] = cursor
        save(cursors, defaults: defaults)
    }

    /// Whether a stream should be walked from the beginning on this run.
    static func needsFullPass(
        _ cursor: StoreSplitImportCursor?,
        periodic: Bool,
        now: Date = .now
    ) -> Bool {
        guard let cursor, cursor.importedThrough != nil else { return true }
        // An interrupted full pass resumes from its saved batches instead of
        // starting over.
        if cursor.fullPassInProgress == true { return false }
        guard periodic else { return false }
        guard let fullPassCompletedAt = cursor.fullPassCompletedAt else { return true }
        return now.timeIntervalSince(fullPassCompletedAt) >= fullPassInterval
    }
}
