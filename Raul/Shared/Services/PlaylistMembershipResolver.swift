import Foundation
import SwiftData

/// The single rule for which portable playlist/queue references are in effect
/// (#442, #519). Used by `StoreSplitUserStateImporter` while it projects
/// UserState membership into the library, and by `PlaylistRestoreFacts` when a
/// Queue or playlist reports how much of it is on this device, so both always
/// agree on the same set of episodes.
///
/// Contract: offer every `PlaylistEntrySync` first, then (for the default
/// queue) every `QueueEntrySync`, each stream newest first (`updatedAt`
/// descending, record `id` ascending as the tie-breaker; see
/// `playlistEntryOrder`/`queueEntryOrder`).
///
/// - Identities are normalized once (`identityKey`), so feed URL variants of
///   the same episode collapse into one reference.
/// - Per playlist and identity, the newest record wins; older aliases are
///   `superseded`. An explicit tombstone wins only when it is the newest.
/// - `QueueEntrySync` is the device-independent tie-breaker for the default
///   queue: it wins over playlist records unless one is strictly newer.
/// - Nothing is ever inferred from absence; only tombstones remove.
struct PlaylistMembershipResolver {
    enum Decision: Equatable, Sendable {
        /// A newer record for the same identity already decided membership.
        case superseded
        /// The newest record is an explicit tombstone.
        case removed
        /// The newest record says the episode belongs to the playlist.
        case active
    }

    private var decidedPlaylistEntries = Set<String>()
    /// Newest playlist-record date per identity in the default queue, so a
    /// queue record only overrides when it is not older.
    private var defaultQueuePlaylistEntryDates: [String: Date] = [:]
    private var decidedQueueIdentities = Set<String>()

    init() {}

    /// - Parameters:
    ///   - playlistKey: The local logical playlist the record maps to (all
    ///     synced IDs that alias one playlist share it).
    ///   - isDefaultQueue: Remember the date so `QueueEntrySync` can defer to
    ///     a strictly newer playlist record.
    mutating func resolvePlaylistEntry(
        playlistKey: String,
        identityKey: String,
        updatedAt: Date,
        isTombstone: Bool,
        isDefaultQueue: Bool
    ) -> Decision {
        guard decidedPlaylistEntries.insert(StableIdentityKey.make(playlistKey, identityKey)).inserted else {
            return .superseded
        }
        if isDefaultQueue {
            defaultQueuePlaylistEntryDates[identityKey] = updatedAt
        }
        return isTombstone ? .removed : .active
    }

    mutating func resolveQueueEntry(
        identityKey: String,
        updatedAt: Date,
        isTombstone: Bool
    ) -> Decision {
        if let playlistDate = defaultQueuePlaylistEntryDates[identityKey], playlistDate > updatedAt {
            return .superseded
        }
        // Newest per identity: an older alias (the same episode under another
        // feed URL spelling) must neither revive a newer removal nor remove a
        // newer re-add.
        guard decidedQueueIdentities.insert(identityKey).inserted else { return .superseded }
        return isTombstone ? .removed : .active
    }

    // MARK: Shared policy

    static func identityKey(feedURL: String, episodeID: String) -> String {
        let normalizedFeedURL = URL(string: feedURL).map {
            $0.podcastFeedComparisonKeys.sorted().first
                ?? PodcastFeedIdentity.normalizedFeedURLString($0)
        } ?? feedURL
        return StableIdentityKey.make(normalizedFeedURL, episodeID)
    }

    static func identityKey(for episode: Episode) -> String {
        let identity = episode.stableEpisodeIdentity
        return identityKey(feedURL: identity.feedURL, episodeID: identity.episodeID)
    }

    /// The episode component of an identity key (`guid:…`, `enclosure:…`).
    static func episodeID(ofIdentityKey key: String) -> String? {
        guard let components = StableIdentityKey.components(from: key), components.count == 2 else {
            return nil
        }
        return components[1]
    }

    /// A reference authored before the episode was finished never brings it
    /// back; a deliberate re-listen (added after completion) still counts.
    /// Gated exactly like the importer and pruner.
    static func isStaleCompletion(isPlayed: Bool, completionDate: Date?, addedAt: Date?) -> Bool {
        PlayedEpisodePlaylistPruner.isEnabled
            && PlayedEpisodeQueuePolicy.isStaleQueueMembership(
                isPlayed: isPlayed,
                completionDate: completionDate,
                addedAt: addedAt
            )
    }

    static func isStaleCompletion(for episode: Episode, addedAt: Date?) -> Bool {
        isStaleCompletion(
            isPlayed: episode.isPlayed,
            completionDate: episode.metaData?.completionDate,
            addedAt: addedAt
        )
    }

    static func playlistLogicalKey(title: String, kindRawValue: String) -> String {
        StableIdentityKey.make(
            title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            kindRawValue
        )
    }

    static var playlistEntryOrder: [SortDescriptor<PlaylistEntrySync>] {
        [SortDescriptor(\PlaylistEntrySync.updatedAt, order: .reverse), SortDescriptor(\PlaylistEntrySync.id)]
    }

    static var queueEntryOrder: [SortDescriptor<QueueEntrySync>] {
        [SortDescriptor(\QueueEntrySync.updatedAt, order: .reverse), SortDescriptor(\QueueEntrySync.id)]
    }

    // MARK: Whole-playlist resolution

    /// One winning, active reference.
    struct Reference: Equatable, Sendable {
        let identityKey: String
        let feedURL: String
        let addedAt: Date
        let sortIndex: Int
    }

    /// Effective active membership of one playlist from records already in
    /// the contract order. `aliasIDs` are every synced playlist ID that maps
    /// to the playlist.
    static func effectiveMembership(
        playlistEntries: [PlaylistEntrySync],
        aliasIDs: Set<String>,
        queueEntries: [QueueEntrySync]?
    ) -> [String: Reference] {
        var resolver = PlaylistMembershipResolver()
        var active: [String: Reference] = [:]
        let isDefaultQueue = queueEntries != nil
        for record in playlistEntries where aliasIDs.contains(record.playlistID) {
            let key = identityKey(feedURL: record.feedURL, episodeID: record.episodeID)
            switch resolver.resolvePlaylistEntry(
                playlistKey: "playlist",
                identityKey: key,
                updatedAt: record.updatedAt,
                isTombstone: record.isDeleted || record.deletedAt != nil,
                isDefaultQueue: isDefaultQueue
            ) {
            case .superseded: continue
            case .removed: active.removeValue(forKey: key)
            case .active:
                active[key] = Reference(identityKey: key, feedURL: record.feedURL,
                                        addedAt: record.addedAt, sortIndex: record.sortIndex)
            }
        }
        for record in queueEntries ?? [] {
            let key = identityKey(feedURL: record.feedURL, episodeID: record.episodeID)
            switch resolver.resolveQueueEntry(
                identityKey: key,
                updatedAt: record.updatedAt,
                isTombstone: record.isDeleted || record.deletedAt != nil
            ) {
            case .superseded: continue
            case .removed: active.removeValue(forKey: key)
            case .active:
                active[key] = Reference(identityKey: key, feedURL: record.feedURL,
                                        addedAt: record.addedAt, sortIndex: record.sortIndex)
            }
        }
        return active
    }
}
