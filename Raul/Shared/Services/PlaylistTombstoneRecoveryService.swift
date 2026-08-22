import Foundation
import SwiftData
import BasicLogger

struct PlaylistTombstoneRecoveryResult: Sendable, Equatable {
    var inspectedEntryCount = 0
    var restoredEntryCount = 0
    var restoredQueueEntryCount = 0
    var earliestRestoredDeletion: Date?
    var latestRestoredDeletion: Date?

    var summary: String {
        guard restoredEntryCount + restoredQueueEntryCount > 0 else {
            return "No tombstones in that window (inspected \(inspectedEntryCount))."
        }
        return "Restored \(restoredEntryCount) playlist entries and "
            + "\(restoredQueueEntryCount) queue entries."
    }
}

/// Undoes playlist-entry tombstones written inside a time window.
///
/// `PlayedEpisodePlaylistPruner` removed entries in two places: it hard-deleted
/// the legacy `PlaylistEntry` rows and it soft-deleted the matching UserState
/// records. Only the second half is recoverable — but it is the half that
/// matters, because the UserState records still carry `sortIndex` and `addedAt`,
/// and the importer rebuilds the legacy rows from them. Clearing the tombstones
/// and re-importing therefore reconstructs the queue, including its order.
///
/// The window is what keeps this from resurrecting episodes the user removed on
/// purpose months ago: only removals stamped inside it are undone.
actor PlaylistTombstoneRecoveryService {
    private let userStateContainer: ModelContainer

    init(userStateContainer: ModelContainer) {
        self.userStateContainer = userStateContainer
    }

    func restoreTombstones(
        deletedOnOrAfter cutoff: Date,
        deletedBefore end: Date = .distantFuture
    ) async -> PlaylistTombstoneRecoveryResult {
        let context = ModelContext(userStateContainer)
        var result = PlaylistTombstoneRecoveryResult()
        let now = Date()

        func isInWindow(_ deletedAt: Date?) -> Bool {
            guard let deletedAt else { return false }
            return deletedAt >= cutoff && deletedAt < end
        }

        func noteWindow(_ deletedAt: Date?) {
            guard let deletedAt else { return }
            if result.earliestRestoredDeletion.map({ deletedAt < $0 }) ?? true {
                result.earliestRestoredDeletion = deletedAt
            }
            if result.latestRestoredDeletion.map({ deletedAt > $0 }) ?? true {
                result.latestRestoredDeletion = deletedAt
            }
        }

        let entries = (try? context.fetch(FetchDescriptor<PlaylistEntrySync>())) ?? []
        result.inspectedEntryCount = entries.count
        for entry in entries where entry.isDeleted || entry.deletedAt != nil {
            guard isInWindow(entry.deletedAt) else { continue }
            noteWindow(entry.deletedAt)
            entry.isDeleted = false
            entry.deletedAt = nil
            // Bump the clock so this revival outranks the tombstone that other
            // devices already hold, instead of losing to it on the next merge.
            entry.updatedAt = now
            result.restoredEntryCount += 1
        }

        let queueEntries = (try? context.fetch(FetchDescriptor<QueueEntrySync>())) ?? []
        result.inspectedEntryCount += queueEntries.count
        for entry in queueEntries where entry.isDeleted || entry.deletedAt != nil {
            guard isInWindow(entry.deletedAt) else { continue }
            noteWindow(entry.deletedAt)
            entry.isDeleted = false
            entry.deletedAt = nil
            entry.updatedAt = now
            result.restoredQueueEntryCount += 1
        }

        context.saveIfNeeded()
        await MainActor.run {
            BasicLogger.shared.log(
                "[Playlist] tombstone recovery \(result.summary) "
                    + "window=\(cutoff)..<\(end)"
            )
        }
        return result
    }

    /// Reports where the queue actually is, without changing anything.
    ///
    /// The two failure modes look identical from the UI — entries deleted and
    /// tombstoned, versus entries still present in UserState but not projected
    /// into the legacy store the app reads from — and they need opposite fixes.
    /// Comparing the live/tombstoned split against the legacy row count is what
    /// tells them apart.
    func diagnosticsReport(legacyContainer: ModelContainer?) async -> [String] {
        let context = ModelContext(userStateContainer)
        let entries = (try? context.fetch(FetchDescriptor<PlaylistEntrySync>())) ?? []
        let queueEntries = (try? context.fetch(FetchDescriptor<QueueEntrySync>())) ?? []
        let playlists = (try? context.fetch(FetchDescriptor<PlaylistSync>())) ?? []

        func split<T>(_ rows: [T], isDeleted: (T) -> Bool) -> (live: Int, dead: Int) {
            let dead = rows.filter(isDeleted).count
            return (rows.count - dead, dead)
        }

        let entrySplit = split(entries) { $0.isDeleted || $0.deletedAt != nil }
        let queueSplit = split(queueEntries) { $0.isDeleted || $0.deletedAt != nil }
        let playlistSplit = split(playlists) { $0.isDeleted || $0.deletedAt != nil }

        var lines: [String] = []
        lines.append(
            "UserState: playlists \(playlistSplit.live) live / \(playlistSplit.dead) tombstoned"
        )
        lines.append(
            "UserState: entries \(entrySplit.live) live / \(entrySplit.dead) tombstoned"
        )
        lines.append(
            "UserState: queue \(queueSplit.live) live / \(queueSplit.dead) tombstoned"
        )

        if let legacyContainer {
            let legacyContext = ModelContext(legacyContainer)
            let legacyPlaylists =
                (try? legacyContext.fetch(FetchDescriptor<Playlist>())) ?? []
            let legacyEntries =
                (try? legacyContext.fetch(FetchDescriptor<PlaylistEntry>())) ?? []
            lines.append(
                "Legacy: playlists \(legacyPlaylists.count), entries \(legacyEntries.count)"
            )

            // The two sides of the membership relationship are declared without
            // an inverse, so they can disagree. Reporting both is what shows
            // whether the rows exist but are invisible to the reader.
            let linked = legacyEntries.filter { $0.playlist != nil }.count
            let withEpisode = legacyEntries.filter { $0.episode != nil }.count
            let viaItems = legacyPlaylists.reduce(0) { $0 + ($1.items?.count ?? 0) }
            lines.append(
                "Legacy entries: linked-to-playlist \(linked), "
                    + "with-episode \(withEpisode), via playlist.items \(viaItems)"
            )
            let distinctEpisodes = Set(
                legacyEntries.compactMap { $0.episode?.url?.absoluteString }
            ).count
            lines.append("Legacy entries: distinct episode URLs \(distinctEpisodes)")

            let podcasts = (try? legacyContext.fetch(FetchDescriptor<Podcast>())) ?? []
            let distinctFeeds = Set(
                podcasts.compactMap { $0.feed?.absoluteString }
            ).count
            let subscribed = podcasts.filter {
                $0.metaData?.isSubscribed != false
            }.count
            lines.append(
                "Legacy podcasts: \(podcasts.count) rows, "
                    + "\(distinctFeeds) distinct feeds, \(subscribed) subscribed"
            )

            let episodeCount =
                (try? legacyContext.fetchCount(FetchDescriptor<Episode>())) ?? 0
            lines.append("Legacy episodes: \(episodeCount) rows")

            // Entries reachable from neither side of the unlinked relationship
            // pair. Whether these are the lost queue or debris left by the
            // CloudKit re-import is the open question, and their episode titles
            // and dates are what answers it.
            let claimed = Set(
                legacyPlaylists.flatMap { playlist -> [PersistentIdentifier] in
                    let viaItems = (playlist.items ?? []).map(\.persistentModelID)
                    let viaBackRef = legacyEntries
                        .filter { $0.playlist?.id == playlist.id }
                        .map(\.persistentModelID)
                    return viaItems + viaBackRef
                }
            )
            let orphans = legacyEntries.filter {
                claimed.contains($0.persistentModelID) == false
            }
            let orphanDates = orphans.compactMap(\.dateAdded).sorted()
            lines.append(
                "Orphan entries: \(orphans.count) "
                    + "(\(orphans.filter { $0.episode != nil }.count) with episode, "
                    + "\(Set(orphans.compactMap { $0.episode?.url?.absoluteString }).count) distinct episodes)"
            )
            if let first = orphanDates.first, let last = orphanDates.last {
                lines.append(
                    "Orphan dateAdded: \(first.formatted(date: .abbreviated, time: .shortened))"
                        + " … \(last.formatted(date: .abbreviated, time: .shortened))"
                )
            }
            for orphan in orphans
                .sorted(by: { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) })
                .prefix(12) {
                let added = orphan.dateAdded?
                    .formatted(date: .abbreviated, time: .shortened) ?? "no date"
                lines.append(
                    "  orphan: \(orphan.episode?.title ?? "<no episode>") — added \(added)"
                )
            }
        }

        var buckets: [Date: Int] = [:]
        for deletedAt in entries.compactMap(\.deletedAt)
            + queueEntries.compactMap(\.deletedAt) {
            buckets[Calendar.current.startOfDay(for: deletedAt), default: 0] += 1
        }
        if buckets.isEmpty {
            lines.append("No tombstones recorded.")
        } else {
            for (day, count) in buckets.sorted(by: { $0.key > $1.key }).prefix(10) {
                lines.append(
                    "tombstoned \(day.formatted(date: .abbreviated, time: .omitted)): \(count)"
                )
            }
        }

        await MainActor.run {
            for line in lines {
                BasicLogger.shared.log("[Playlist] diagnostics \(line)")
            }
        }
        return lines
    }
}
