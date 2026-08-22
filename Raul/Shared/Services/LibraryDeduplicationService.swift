import Foundation
import SwiftData
import BasicLogger

struct LibraryDeduplicationReport: Sendable, Equatable {
    var isDryRun = true
    var podcastGroups = 0
    var podcastsRemoved = 0
    var episodesReparented = 0
    var episodeGroups = 0
    var episodesRemoved = 0
    var playlistEntriesRepointed = 0
    var playlistEntriesRemoved = 0
    var playlistEntriesRelinked = 0
    /// Rows that belong to no playlist on either side of the unlinked pair.
    /// Counted and reported, never touched: until we know whether they are the
    /// lost queue or re-import debris, deleting them would destroy the evidence.
    var orphanEntries = 0
    var orphanEntriesWithEpisode = 0
    var orphanDistinctEpisodes = 0
    var playSessionsRemoved = 0
    var playSessionsTotal = 0

    var summary: String {
        let prefix = isDryRun ? "Would collapse" : "Collapsed"
        return """
        \(prefix) \(podcastGroups) duplicate podcast groups (\(podcastsRemoved) rows), \
        moving \(episodesReparented) episodes.
        \(prefix) \(episodeGroups) duplicate episode groups (\(episodesRemoved) rows).
        Playlist: \(playlistEntriesRepointed) entries re-pointed, \
        \(playlistEntriesRemoved) removed, \(playlistEntriesRelinked) relinked.
        Orphans: \(orphanEntries) entries belong to no playlist \
        (\(orphanEntriesWithEpisode) still name an episode, \
        \(orphanDistinctEpisodes) distinct) — left untouched.
        Play sessions: \(playSessionsRemoved) of \(playSessionsTotal) are duplicates.
        """
    }
}

/// Collapses the duplicate podcasts and episodes produced by re-attaching the
/// legacy store to CloudKit, and repairs playlist membership afterwards.
///
/// Three things about this schema make the work delicate:
///
/// * Nothing is `@Attribute(.unique)`, so duplicates are ordinary rows and only
///   an explicit pass can merge them.
/// * `Podcast.episodes` cascades on delete while `Episode.podcast` is a separate
///   relationship with no inverse. Re-pointing an episode is therefore *not*
///   enough — it has to be removed from the loser's `episodes` array too, or
///   deleting the loser takes the episode with it.
/// * `Playlist.items` / `PlaylistEntry.playlist` and `Episode.playlist` /
///   `PlaylistEntry.episode` are likewise unlinked pairs, so membership has to be
///   written on both sides to be visible to both readers.
actor LibraryDeduplicationService {
    private let legacyContainer: ModelContainer

    init(legacyContainer: ModelContainer) {
        self.legacyContainer = legacyContainer
    }

    func run(dryRun: Bool) async -> LibraryDeduplicationReport {
        let context = ModelContext(legacyContainer)
        context.autosaveEnabled = false
        var report = LibraryDeduplicationReport(isDryRun: dryRun)

        // Planning is strictly read-only, so a dry run cannot touch the store
        // even if it throws part-way. Nothing is mutated until `apply`.
        let plan = makePlan(in: context, report: &report)

        if dryRun == false {
            apply(plan, in: context, report: &report)
            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run {
                        BasicLogger.shared.log("[Dedup] save failed: \(message)")
                    }
                }
            }
        }

        let summary = report.summary
        await MainActor.run { BasicLogger.shared.log("[Dedup] \(summary)") }
        return report
    }

    /// What the pass intends to do. Holding identifiers rather than models keeps
    /// the plan valid across the saves that `apply` performs.
    private struct Plan {
        var podcastMerges: [(survivor: Podcast, losers: [Podcast])] = []
        var episodeMerges: [(survivor: Episode, losers: [Episode])] = []
        var playlistPlans: [(playlist: Playlist, keep: [PlaylistEntry], drop: [PlaylistEntry])] = []
        var playSessionDrops: [PlaySession] = []
    }

    private func makePlan(
        in context: ModelContext,
        report: inout LibraryDeduplicationReport
    ) -> Plan {
        var plan = Plan()
        planPodcasts(in: context, plan: &plan, report: &report)
        planEpisodes(in: context, plan: &plan, report: &report)
        planPlaylists(in: context, plan: &plan, report: &report)
        planPlaySessions(in: context, plan: &plan, report: &report)
        return plan
    }

    private func apply(
        _ plan: Plan,
        in context: ModelContext,
        report: inout LibraryDeduplicationReport
    ) {
        applyPodcastMerges(plan, in: context, report: &report)
        applyEpisodeMerges(plan, in: context, report: &report)
        applyPlaylistPlans(plan, in: context)
        for session in plan.playSessionDrops {
            session.episode = nil
            context.delete(session)
        }
    }

    // MARK: - Podcasts

    private func planPodcasts(
        in context: ModelContext,
        plan: inout Plan,
        report: inout LibraryDeduplicationReport
    ) {
        let podcasts = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []
        guard podcasts.count > 1 else { return }

        // One podcast yields several comparison keys, so grouping has to be
        // transitive: two rows belong together if they share *any* key.
        var groupByKey: [String: Int] = [:]
        var groups: [[Podcast]] = []
        for podcast in podcasts.sorted(by: { podcastTiebreak($0) < podcastTiebreak($1) }) {
            guard let feed = podcast.feed else { continue }
            let keys = feed.podcastFeedComparisonKeys
            let existing = Set(keys.compactMap { groupByKey[$0] })
            if let target = existing.min() {
                groups[target].append(podcast)
                for stale in existing where stale != target {
                    groups[target].append(contentsOf: groups[stale])
                    groups[stale] = []
                    for (key, value) in groupByKey where value == stale {
                        groupByKey[key] = target
                    }
                }
                for key in keys { groupByKey[key] = target }
            } else {
                groups.append([podcast])
                for key in keys { groupByKey[key] = groups.count - 1 }
            }
        }

        for group in groups where group.count > 1 {
            guard let survivor = bestPodcast(in: group) else { continue }
            let losers = group.filter { $0 !== survivor }
            report.podcastGroups += 1
            report.podcastsRemoved += losers.count
            report.episodesReparented += losers.reduce(0) { $0 + ($1.episodes?.count ?? 0) }
            plan.podcastMerges.append((survivor, losers))
        }
    }

    /// Subscription state outranks size: an unsubscribed copy with more episodes
    /// is still the wrong row to keep. The trailing string comparison only breaks
    /// exact ties, and exists so two runs over the same data agree.
    private func bestPodcast(in group: [Podcast]) -> Podcast? {
        group.min { lhs, rhs in
            let l = podcastRank(lhs)
            let r = podcastRank(rhs)
            if l != r { return lexicographicallyPrecedes(r, l) }
            return podcastTiebreak(lhs) < podcastTiebreak(rhs)
        }
    }

    private func podcastRank(_ podcast: Podcast) -> [Int] {
        [
            podcast.metaData?.isSubscribed == true ? 1 : 0,
            podcast.episodes?.count ?? 0,
            podcast.metaData?.subscriptionDate == nil ? 0 : 1
        ]
    }

    private func podcastTiebreak(_ podcast: Podcast) -> String {
        "\(podcast.metaData?.subscriptionDate?.timeIntervalSince1970 ?? .greatestFiniteMagnitude)|\(podcast.title)"
    }

    private func applyPodcastMerges(
        _ plan: Plan,
        in context: ModelContext,
        report: inout LibraryDeduplicationReport
    ) {
        for merge in plan.podcastMerges {
            for loser in merge.losers {
                for episode in loser.episodes ?? [] {
                    merge.survivor.episodes = (merge.survivor.episodes ?? []) + [episode]
                    episode.podcast = merge.survivor
                }
                mergePodcastMetadata(from: loser, into: merge.survivor)
                // `Podcast.episodes` cascades and `Episode.podcast` has no
                // inverse, so the survivor's new episodes are still listed on the
                // loser. Emptying the array is what stops the delete taking them.
                loser.episodes = []
                context.delete(loser)
            }
        }
    }

    private func mergePodcastMetadata(from loser: Podcast, into survivor: Podcast) {
        if survivor.metaData == nil, let metadata = loser.metaData {
            loser.metaData = nil
            survivor.metaData = metadata
        } else if let loserMeta = loser.metaData, let survivorMeta = survivor.metaData {
            if loserMeta.isSubscribed == true { survivorMeta.isSubscribed = true }
            if let date = loserMeta.subscriptionDate {
                survivorMeta.subscriptionDate = min(
                    survivorMeta.subscriptionDate ?? date,
                    date
                )
            }
        }
        if survivor.settings == nil, let settings = loser.settings {
            loser.settings = nil
            survivor.settings = settings
        }
    }

    // MARK: - Episodes

    private func planEpisodes(
        in context: ModelContext,
        plan: inout Plan,
        report: inout LibraryDeduplicationReport
    ) {
        let episodes = (try? context.fetch(FetchDescriptor<Episode>())) ?? []
        guard episodes.count > 1 else { return }

        var byIdentity: [String: [Episode]] = [:]
        for episode in episodes {
            guard let key = episodeIdentity(episode) else { continue }
            byIdentity[key, default: []].append(episode)
        }

        // Sorted so the pass visits groups in a fixed order regardless of how the
        // dictionary happens to hash.
        for key in byIdentity.keys.sorted() {
            let group = byIdentity[key] ?? []
            guard group.count > 1, let survivor = bestEpisode(in: group) else { continue }
            let losers = group.filter { $0 !== survivor }
            report.episodeGroups += 1
            report.episodesRemoved += losers.count
            plan.episodeMerges.append((survivor, losers))
        }
    }

    /// Duplicates of one episode share a GUID when the feed provides one; the
    /// enclosure URL is the fallback. An episode with neither is left alone
    /// rather than risking a merge of genuinely different rows.
    private func episodeIdentity(_ episode: Episode) -> String? {
        if let guid = episode.guid, guid.isEmpty == false {
            return "guid:\(guid.lowercased())"
        }
        if let url = episode.url {
            return "url:\(url.absoluteString.lowercased())"
        }
        return nil
    }

    private func bestEpisode(in group: [Episode]) -> Episode? {
        group.min { lhs, rhs in
            let l = episodeRank(lhs)
            let r = episodeRank(rhs)
            if l != r { return lexicographicallyPrecedes(r, l) }
            return episodeTiebreak(lhs) < episodeTiebreak(rhs)
        }
    }

    /// Keep the copy carrying the most playback state.
    private func episodeRank(_ episode: Episode) -> [Int] {
        let metadata = episode.metaData
        return [
            metadata?.completionDate == nil ? 0 : 1,
            Int(metadata?.maxPlayposition ?? 0),
            (episode.playSessions?.count ?? 0) + (episode.bookmarks?.count ?? 0),
            metadata?.isAvailableLocally == true ? 1 : 0
        ]
    }

    private func episodeTiebreak(_ episode: Episode) -> String {
        "\(episode.publishDate?.timeIntervalSince1970 ?? .greatestFiniteMagnitude)|\(episode.title)"
    }

    private func applyEpisodeMerges(
        _ plan: Plan,
        in context: ModelContext,
        report: inout LibraryDeduplicationReport
    ) {
        for merge in plan.episodeMerges {
            for loser in merge.losers {
                mergeEpisodeMetadata(from: loser, into: merge.survivor)

                // `PlaySession.episode` has a real inverse, so assigning it moves
                // the session off the loser on both sides at once.
                for session in loser.playSessions ?? [] {
                    session.episode = merge.survivor
                }
                for entry in loser.playlist ?? [] {
                    entry.episode = merge.survivor
                    merge.survivor.playlist = (merge.survivor.playlist ?? []) + [entry]
                    report.playlistEntriesRepointed += 1
                }
                loser.playlist = []
                loser.podcast?.episodes?.removeAll { $0 === loser }
                context.delete(loser)
            }
        }
    }

    /// Takes the strongest value from each side.
    ///
    /// `totalListenTime` is deliberately `max`, not a sum: the rows are copies of
    /// one episode, so adding them is exactly the double-count that inflated the
    /// lifetime statistics in the first place.
    private func mergeEpisodeMetadata(from loser: Episode, into survivor: Episode) {
        guard let loserMeta = loser.metaData else { return }
        guard let survivorMeta = survivor.metaData else {
            loser.metaData = nil
            survivor.metaData = loserMeta
            return
        }

        survivorMeta.maxPlayposition = max(
            survivorMeta.maxPlayposition ?? 0,
            loserMeta.maxPlayposition ?? 0
        )
        survivorMeta.playPosition = max(
            survivorMeta.playPosition ?? 0,
            loserMeta.playPosition ?? 0
        )
        survivorMeta.totalListenTime = max(
            survivorMeta.totalListenTime,
            loserMeta.totalListenTime
        )
        if let loserCompletion = loserMeta.completionDate {
            survivorMeta.completionDate = min(
                survivorMeta.completionDate ?? loserCompletion,
                loserCompletion
            )
        }
        if let loserPlayed = loserMeta.lastPlayed {
            survivorMeta.lastPlayed = max(
                survivorMeta.lastPlayed ?? loserPlayed,
                loserPlayed
            )
        }
        if loserMeta.isAvailableLocally { survivorMeta.isAvailableLocally = true }
        if loserMeta.isHistory == true { survivorMeta.isHistory = true }
        if loserMeta.isArchived == true { survivorMeta.isArchived = true }
        survivorMeta.reconcileLegacyStatus()
    }

    // MARK: - Playlists

    /// Plans one entry per episode per playlist, reading membership from *both*
    /// sides of the unlinked relationship pair so an entry linked only one way
    /// still counts as a member.
    private func planPlaylists(
        in context: ModelContext,
        plan: inout Plan,
        report: inout LibraryDeduplicationReport
    ) {
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        let allEntries = (try? context.fetch(FetchDescriptor<PlaylistEntry>())) ?? []

        // Episodes that will be gone after `apply`, mapped to their survivor, so
        // the plan dedupes on the identity the entry will actually have.
        var survivingEpisode: [PersistentIdentifier: Episode] = [:]
        for merge in plan.episodeMerges {
            for loser in merge.losers {
                survivingEpisode[loser.persistentModelID] = merge.survivor
            }
        }

        var claimed = Set<PersistentIdentifier>()
        for playlist in playlists where playlist.isSmartPlaylist == false {
            var members = allEntries.filter { $0.playlist?.id == playlist.id }
            for entry in playlist.items ?? []
            where members.contains(where: { $0 === entry }) == false {
                members.append(entry)
            }

            var seenEpisodes = Set<String>()
            var keep: [PlaylistEntry] = []
            var drop: [PlaylistEntry] = []
            for entry in members.sorted(by: entryOrder) {
                let episode = entry.episode.map {
                    survivingEpisode[$0.persistentModelID] ?? $0
                }
                guard let url = episode?.url else {
                    drop.append(entry)
                    continue
                }
                guard seenEpisodes.insert(url.absoluteString).inserted else {
                    drop.append(entry)
                    continue
                }
                keep.append(entry)
            }

            report.playlistEntriesRemoved += drop.count
            report.playlistEntriesRelinked += keep.count
            plan.playlistPlans.append((playlist, keep, drop))
            claimed.formUnion(members.map(\.persistentModelID))
        }

        let orphans = allEntries.filter {
            claimed.contains($0.persistentModelID) == false
        }
        report.orphanEntries = orphans.count
        report.orphanEntriesWithEpisode = orphans.filter { $0.episode != nil }.count
        report.orphanDistinctEpisodes = Set(
            orphans.compactMap { $0.episode?.url?.absoluteString }
        ).count
    }

    private func applyPlaylistPlans(_ plan: Plan, in context: ModelContext) {
        for entry in plan.playlistPlans {
            for dropped in entry.drop {
                dropped.playlist = nil
                dropped.episode = nil
                context.delete(dropped)
            }
            for (index, kept) in entry.keep.enumerated() {
                kept.order = index
                // Both sides, because neither relationship maintains the other.
                kept.playlist = entry.playlist
                if let episode = kept.episode,
                   (episode.playlist ?? []).contains(where: { $0 === kept }) == false {
                    episode.playlist = (episode.playlist ?? []) + [kept]
                }
            }
            entry.playlist.items = entry.keep
        }
    }

    /// Descending compare for the rank vectors, which are ordered by importance.
    private func lexicographicallyPrecedes(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        lhs.lexicographicallyPrecedes(rhs)
    }

    // MARK: - Play sessions

    /// Collapses re-imported copies of the same listening session.
    ///
    /// This is what the statistics actually rest on: `rebuildListeningStats`
    /// recomputes the hourly buckets and every summary from `PlaySession` rows,
    /// so a duplicated session is counted twice no matter how often the analytics
    /// are rebuilt. Sessions carry a stored `id`, and a CloudKit re-import copies
    /// that value, which makes it a precise duplicate key; the start/end fallback
    /// catches copies that arrived without one.
    private func planPlaySessions(
        in context: ModelContext,
        plan: inout Plan,
        report: inout LibraryDeduplicationReport
    ) {
        let sessions = (try? context.fetch(FetchDescriptor<PlaySession>())) ?? []
        report.playSessionsTotal = sessions.count
        guard sessions.count > 1 else { return }

        var survivingEpisode: [PersistentIdentifier: Episode] = [:]
        for merge in plan.episodeMerges {
            for loser in merge.losers {
                survivingEpisode[loser.persistentModelID] = merge.survivor
            }
        }

        var seen: [String: PlaySession] = [:]
        for session in sessions.sorted(by: { sessionTiebreak($0) < sessionTiebreak($1) }) {
            let episode = session.episode.map {
                survivingEpisode[$0.persistentModelID] ?? $0
            }
            let key: String
            if let id = session.id {
                key = "id:\(id.uuidString)"
            } else {
                key = [
                    episode?.url?.absoluteString ?? "-",
                    "\(session.startTime?.timeIntervalSince1970 ?? -1)",
                    "\(session.endTime?.timeIntervalSince1970 ?? -1)",
                    session.sourceDeviceID ?? "-"
                ].joined(separator: "|")
            }

            guard let incumbent = seen[key] else {
                seen[key] = session
                continue
            }
            // Keep the richer row: a copy truncated by an interrupted import
            // would otherwise win and shorten the session.
            if lexicographicallyPrecedes(sessionRank(incumbent), sessionRank(session)) {
                seen[key] = session
                plan.playSessionDrops.append(incumbent)
            } else {
                plan.playSessionDrops.append(session)
            }
        }
        report.playSessionsRemoved = plan.playSessionDrops.count
    }

    private func sessionRank(_ session: PlaySession) -> [Int] {
        [
            session.endTime == nil ? 0 : 1,
            session.segments?.count ?? 0,
            Int((session.endPosition ?? 0) - (session.startPosition ?? 0))
        ]
    }

    private func sessionTiebreak(_ session: PlaySession) -> String {
        "\(session.startTime?.timeIntervalSince1970 ?? .greatestFiniteMagnitude)|\(session.id?.uuidString ?? "")"
    }

    private func entryOrder(_ lhs: PlaylistEntry, _ rhs: PlaylistEntry) -> Bool {
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        if lhs.dateAdded != rhs.dateAdded {
            return (lhs.dateAdded ?? .distantPast) < (rhs.dateAdded ?? .distantPast)
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
