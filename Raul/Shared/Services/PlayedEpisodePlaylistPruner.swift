//
//  PlayedEpisodePlaylistPruner.swift
//  Raul
//

import Foundation
import SwiftData
import BasicLogger

/// The single rule for deciding whether a playlist entry belongs to an episode
/// that has already been listened to.
///
/// Membership and completion are stored independently — and, since the store
/// split, they can arrive from CloudKit at different times and from different
/// devices. Comparing the two dates is what separates the two cases that
/// otherwise look identical:
///
/// * an entry queued *before* the episode was finished is leftover queue state
///   that a stale projection revived, and must go, and
/// * an entry queued *after* the episode was finished is a deliberate re-listen,
///   which must be left alone.
enum PlayedEpisodeQueuePolicy {
    static func isStaleQueueMembership(
        isPlayed: Bool,
        completionDate: Date?,
        addedAt: Date?
    ) -> Bool {
        guard isPlayed else { return false }
        // Played without a completion stamp means the progress threshold decided
        // it; there is no "finished at" instant to compare against, so the entry
        // cannot be a deliberate re-listen.
        guard let completionDate else { return true }
        guard let addedAt else { return true }
        return addedAt <= completionDate
    }

    static func isStaleQueueMembership(for episode: Episode, addedAt: Date?) -> Bool {
        isStaleQueueMembership(
            isPlayed: episode.isPlayed,
            completionDate: episode.metaData?.completionDate,
            addedAt: addedAt
        )
    }
}

struct PlayedEpisodePruneResult: Sendable, Equatable {
    var removedEntryCount: Int = 0
    var affectedPlaylistCount: Int = 0
}

/// Enforces "a played episode is not a playlist member" across every manual
/// playlist, and tombstones what it removes so the removal survives the next
/// CloudKit round trip instead of being re-imported.
///
/// Runs after every user-state import: an import is the one moment when entries
/// authored on another device (or by an older build that predates the tombstone
/// rules) can land in the local queue.
actor PlayedEpisodePlaylistPruner {
    static let isEnabledKey = "playlist.playedEpisodePrunerEnabled"

    /// Whether the pruner may actually delete and tombstone.
    ///
    /// Off by default. The removals are hard deletes in the legacy store *and*
    /// tombstones in UserState, so a single over-broad pass propagates to every
    /// device and cannot be undone by republishing. Until the membership rule is
    /// backed by evidence from a real library, the pruner only reports what it
    /// would have removed.
    ///
    /// Backed by a default rather than a constant so it can be switched on
    /// deliberately — by a test exercising the removal path, or once the rule is
    /// trusted again — without another edit here.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: isEnabledKey)
    }

    private let legacyContainer: ModelContainer

    init(legacyContainer: ModelContainer) {
        self.legacyContainer = legacyContainer
    }

    @discardableResult
    func prune() async -> PlayedEpisodePruneResult {
        let context = ModelContext(legacyContainer)
        let entries = (try? context.fetch(FetchDescriptor<PlaylistEntry>())) ?? []
        guard entries.isEmpty == false else { return PlayedEpisodePruneResult() }

        // Never dequeue what is on air. The finish handler removes it in the same
        // turn it hands playback to the successor; racing that here would drop the
        // queue position the player is about to advance from.
        let nowPlayingURL = await MainActor.run { Player.shared.currentEpisodeURL }

        var reports: [String] = []
        var removals: [StoreSplitPlaylistRemoval] = []
        var affectedPlaylistIDs = Set<UUID>()
        var removedEntryIDs = Set<UUID>()
        var result = PlayedEpisodePruneResult()

        for entry in entries {
            guard let playlist = entry.playlist,
                  playlist.isSmartPlaylist == false,
                  let episode = entry.episode else { continue }
            guard episode.url != nowPlayingURL else { continue }
            guard PlayedEpisodeQueuePolicy.isStaleQueueMembership(
                for: episode,
                addedAt: entry.dateAdded
            ) else { continue }

            reports.append(
                "playlist=\(playlist.displayTitle) "
                    + "episode=\(episode.title) "
                    + "completionDate=\(String(describing: episode.metaData?.completionDate)) "
                    + "isHistory=\(String(describing: episode.metaData?.isHistory)) "
                    + "status=\(String(describing: episode.metaData?.status)) "
                    + "maxPlayProgress=\(episode.maxPlayProgress) "
                    + "dateAdded=\(String(describing: entry.dateAdded))"
            )

            guard Self.isEnabled else { continue }

            removals.append(
                StoreSplitPlaylistRemoval(
                    playlistID: playlist.storeSplitSyncID,
                    isDefaultQueue: playlist.title == Playlist.defaultQueueTitle,
                    identity: episode.stableEpisodeIdentity
                )
            )
            affectedPlaylistIDs.insert(playlist.id)
            removedEntryIDs.insert(entry.id)
            context.delete(entry)
            episode.refresh.toggle()
            result.removedEntryCount += 1
        }

        if Self.isEnabled == false {
            await MainActor.run {
                BasicLogger.shared.log(
                    "[Playlist] pruner disabled — would have removed \(reports.count) of \(entries.count) entries"
                )
                for report in reports {
                    BasicLogger.shared.log("[Playlist] would-prune \(report)")
                }
            }
            return result
        }

        guard result.removedEntryCount > 0 else { return result }
        result.affectedPlaylistCount = affectedPlaylistIDs.count

        for playlistID in affectedPlaylistIDs {
            let descriptor = FetchDescriptor<PlaylistEntry>(
                predicate: #Predicate<PlaylistEntry> { entry in
                    entry.playlist?.id == playlistID
                },
                sortBy: [
                    SortDescriptor(\PlaylistEntry.order, order: .forward),
                    SortDescriptor(\PlaylistEntry.dateAdded, order: .forward)
                ]
            )
            // Filter explicitly rather than trusting the fetch to exclude rows
            // deleted but not yet committed in this context.
            let remaining = ((try? context.fetch(descriptor)) ?? [])
                .filter { removedEntryIDs.contains($0.id) == false }
            for (index, entry) in remaining.enumerated() where entry.order != index {
                entry.order = index
            }
        }

        context.saveIfNeeded()
        await MainActor.run {
            BasicLogger.shared.log(
                "[Playlist] pruned \(result.removedEntryCount) played episode(s) from \(result.affectedPlaylistCount) playlist(s)"
            )
        }

        await tombstone(removals)
        await PlayNextWidgetSync.refresh(
            using: legacyContainer,
            playlistIDs: affectedPlaylistIDs
        )
        WatchSyncCoordinator.refreshSoon(force: true)

        return result
    }

    private func tombstone(_ removals: [StoreSplitPlaylistRemoval]) async {
        guard removals.isEmpty == false else { return }
        await ModelContainerManager.shared.prepareSplitStores()
        guard let userStateContainer = await MainActor.run(body: {
            ModelContainerManager.shared.preparedUserStateContainer
        }) else { return }
        await StoreSplitPlaylistSyncWriter(modelContainer: userStateContainer)
            .tombstone(removals)
    }
}
