//
//  PlaylistModelActor.swift
//  Raul
//
//  Created by Holger Krupp on 23.04.25.
//
import SwiftData
import Foundation
import BasicLogger

actor PlaylistModelActor {
    enum RemovalOrigin: Sendable {
        case user
        case policyMaintenance
    }

    /// Who asked for an episode to enter a playlist.
    ///
    /// Only `.user` may queue an episode that has already been played. Every
    /// automatic path (playback bookkeeping, auto-download policy, feed intake)
    /// must stay out of the way of a finished episode, otherwise a re-queue
    /// racing the finish handler puts the episode back at the top of Up Next.
    enum InsertionOrigin: Sendable {
        case user
        case automatic
    }

    // Nonisolated so you can read them without await (types are value types)
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor

    // Actor-isolated context (do not cross actors with it)
    private let modelContext: ModelContext

    // We never store model instances; only the stable ID
    private let playlistID: UUID

    // MARK: - Inits

    /// Initialize by known playlist ID. Throws if playlist can't be found.
    public init(modelContainer: ModelContainer? = nil, playlistID: UUID) throws {
        guard let container = modelContainer else {
            fatalError("PlaylistModelActor requires a modelContainer to be passed in from the main actor.")
        }
        self.modelContainer = container
        self.modelContext = ModelContext(container)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
        self.playlistID = playlistID

        let descriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate<Playlist> { $0.id == playlistID }
        )
        guard try modelContext.fetch(descriptor).first != nil else {
            throw NSError(
                domain: "PlaylistModelActor",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Playlist not found for id \(playlistID)"]
            )
        }
    }

    public init(activePlaybackPlaylistIn modelContainer: ModelContainer? = nil) throws {
        guard let container = modelContainer else {
            fatalError("PlaylistModelActor requires a modelContainer to be passed in from the main actor.")
        }

        let selectionContext = ModelContext(container)
        let selectedPlaylistID = Playlist.resolvedSelectedManualPlaylistID(
            in: selectionContext
        )

        self.modelContainer = container
        self.modelContext = ModelContext(container)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
        self.playlistID = selectedPlaylistID

        let descriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate<Playlist> { $0.id == selectedPlaylistID }
        )
        guard try modelContext.fetch(descriptor).first != nil else {
            throw NSError(
                domain: "PlaylistModelActor",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Selected playlist not found for id \(selectedPlaylistID)"]
            )
        }
    }

    /// Initialize by title; creates the playlist if it doesn't exist.
    public init(modelContainer: ModelContainer? = nil,
                playlistTitle: String = Playlist.defaultQueueTitle) throws {
        guard let container = modelContainer else {
            fatalError("PlaylistModelActor requires a modelContainer to be passed in from the main actor.")
        }
        self.modelContainer = container
        self.modelContext = ModelContext(container)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)

        // Fetch once (no predicate) then filter in-memory to avoid early predicate path
        let all = try modelContext.fetch(FetchDescriptor<Playlist>())
        if let existing = all.first(where: { $0.title == playlistTitle }) {
            self.playlistID = existing.id
        } else {
            let newPlaylist = Playlist()
            newPlaylist.title = playlistTitle
            if playlistTitle == Playlist.defaultQueueTitle {
                newPlaylist.deleteable = false
                newPlaylist.sortIndex = 0
                newPlaylist.kind = .manual
            }
            modelContext.insert(newPlaylist)
            try modelContext.save()
            self.playlistID = newPlaylist.id
        }
        
    }

    // MARK: - Private helpers

    private func logAutoDownload(_ message: String) {
        Task { @MainActor in
            BasicLogger.shared.log("[AutoDL] \(message)")
        }
    }

    /// Always fetch the current playlist in this actor’s context.
    private func fetchPlaylist() throws -> Playlist? {

        let predicate = #Predicate<Playlist> { $0.id == playlistID }
        let descriptor = FetchDescriptor<Playlist>(predicate: predicate)
        return try modelContext.fetch(descriptor).first
    }

    private func fetchEpisode(byURL fileURL: URL) throws -> Episode? {
        let predicate = #Predicate<Episode> { $0.url == fileURL }
        return try modelContext.fetch(FetchDescriptor<Episode>(predicate: predicate)).first
    }

    private func fetchEpisodes(byURL fileURL: URL) throws -> [Episode] {
        let predicate = #Predicate<Episode> { $0.url == fileURL }
        return try modelContext.fetch(FetchDescriptor<Episode>(predicate: predicate))
    }

    /// Fetch entries in storage order instead of sorting the relationship
    /// collection in memory. SwiftData can invalidate a relationship object
    /// while another context is updating the playlist; reading `order` from
    /// that invalidated object traps inside the generated property getter.
    private func fetchOrderedEntries() throws -> [PlaylistEntry] {
        let predicate = #Predicate<PlaylistEntry> { entry in
            entry.playlist?.id == playlistID
        }
        let descriptor = FetchDescriptor<PlaylistEntry>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\PlaylistEntry.order, order: .forward),
                SortDescriptor(\PlaylistEntry.dateAdded, order: .forward)
            ]
        )
        return try modelContext.fetch(descriptor)
    }

    // MARK: - Public API (safe)

    /// Re-fetches and returns the up-to-date playlist. Useful if callers want to verify presence.
    @discardableResult
    func refresh() throws -> Playlist {
        guard let p = try fetchPlaylist() else {
            throw NSError(domain: "PlaylistModelActor", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Playlist not found during refresh"])
        }
        return p
    }

    private func allEpisodes() throws -> [Episode] {
        try modelContext.fetch(FetchDescriptor<Episode>())
    }

    private func orderedEpisodes(for playlist: Playlist) throws -> [Episode] {
        if playlist.isSmartPlaylist {
            let episodes = try allEpisodes()
            return SmartPlaylistEngine.episodes(from: episodes, for: playlist)
        }

        return try fetchOrderedEntries().compactMap { $0.episode }
    }

    func orderedEpisodes() throws -> [Episode] {
        guard let playlist = try fetchPlaylist() else { return [] }
        return try orderedEpisodes(for: playlist)
    }

    public func orderedEpisodeURLs() throws -> [URL] {
        try orderedEpisodes().compactMap(\.url)
    }

    public func firstEpisodeURL() throws -> URL? {
        guard let playlist = try fetchPlaylist() else { return nil }
        return try firstEpisodeURL(in: playlist)
    }

    private func firstEpisodeURL(in playlist: Playlist) throws -> URL? {
        if playlist.isSmartPlaylist {
            return try orderedEpisodes(for: playlist).lazy.compactMap(\.url).first
        }
        // Lazily, so only the first entry's episode is faulted in instead of
        // the whole queue.
        return try fetchOrderedEntries().lazy.compactMap { $0.episode?.url }.first
    }

    /// Episode playback should resume with at launch, resolved in one actor turn.
    ///
    /// `preferredURL` (the last played episode) wins when it is still queued.
    /// For a manual playlist that membership test is a bounded entry fetch, so
    /// the launch path never has to materialize the full queue just to decide.
    func launchEpisodeURL(preferring preferredURL: URL?) throws -> URL? {
        guard let playlist = try fetchPlaylist() else { return nil }

        if playlist.isSmartPlaylist {
            let urls = try orderedEpisodes(for: playlist).compactMap(\.url)
            if let preferredURL, urls.contains(preferredURL) { return preferredURL }
            return urls.first
        }

        if let preferredURL, try containsEntry(for: preferredURL) {
            return preferredURL
        }
        return try firstEpisodeURL(in: playlist)
    }

    private func containsEntry(for episodeURL: URL) throws -> Bool {
        let playlistID = playlistID
        var descriptor = FetchDescriptor<PlaylistEntry>(
            predicate: #Predicate<PlaylistEntry> { entry in
                entry.playlist?.id == playlistID && entry.episode?.url == episodeURL
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).isEmpty == false
    }

    func nextEpisodeURL() throws -> URL? {
        try orderedEpisodes().dropFirst().compactMap(\.url).first
    }

    func nextEpisodeURL(after episodeURL: URL) throws -> URL? {
        let urls = try orderedEpisodeURLs()
        guard urls.isEmpty == false else { return nil }

        guard let currentIndex = urls.firstIndex(of: episodeURL) else {
            return urls.first
        }

        let nextIndex = urls.index(after: currentIndex)
        guard nextIndex < urls.endIndex else { return nil }
        return urls[nextIndex]
    }

    /// Removes a finished episode from every manual playlist and returns the playback
    /// playlist's successor.
    ///
    /// Successor selection and removal deliberately happen in the same actor turn and are
    /// committed before this method returns. This prevents playback from selecting from one
    /// queue snapshot while completion bookkeeping removes from a newer one later on.
    func dequeueFinishedEpisodeAndReturnNext(after episodeURL: URL) async throws -> URL? {
        guard let playlist = try fetchPlaylist() else { return nil }
        try markEpisodeFinished(episodeURL)
        guard playlist.isSmartPlaylist == false else {
            if modelContext.hasChanges {
                try modelContext.save()
            }
            return try nextEpisodeURL(after: episodeURL)
        }

        let orderedEntries = try fetchOrderedEntries()
        let firstFinishedIndex = orderedEntries.firstIndex {
            $0.episode?.url == episodeURL
        }
        let remainingEntries = orderedEntries.filter {
            $0.episode?.url != episodeURL
        }

        let nextEpisodeURL: URL?
        if let firstFinishedIndex {
            nextEpisodeURL = orderedEntries
                .dropFirst(firstFinishedIndex + 1)
                .first(where: { $0.episode?.url != episodeURL })?
                .episode?.url
        } else {
            // Completion may be retried after another path already dequeued the episode.
            // Continuing with the first queued item keeps the operation idempotent.
            nextEpisodeURL = remainingEntries.first?.episode?.url
        }

        let matchingEntries = try modelContext.fetch(FetchDescriptor<PlaylistEntry>(
            predicate: #Predicate<PlaylistEntry> { entry in
                entry.episode?.url == episodeURL
            }
        ))
        guard matchingEntries.isEmpty == false else {
            if modelContext.hasChanges {
                try modelContext.save()
            }
            return nextEpisodeURL
        }

        let affectedPlaylistIDs = Set(matchingEntries.compactMap { $0.playlist?.id })

        let removals = matchingEntries.compactMap { entry -> StoreSplitPlaylistRemoval? in
            guard let entryPlaylist = entry.playlist,
                  let identity = entry.episode?.stableEpisodeIdentity else { return nil }
            return StoreSplitPlaylistRemoval(
                playlistID: entryPlaylist.storeSplitSyncID,
                isDefaultQueue: entryPlaylist.title == Playlist.defaultQueueTitle,
                identity: identity
            )
        }

        for entry in matchingEntries {
            entry.episode?.refresh.toggle()
            modelContext.delete(entry)
        }
        for affectedPlaylistID in affectedPlaylistIDs {
            let entries = try modelContext.fetch(FetchDescriptor<PlaylistEntry>(
                predicate: #Predicate<PlaylistEntry> { entry in
                    entry.playlist?.id == affectedPlaylistID
                },
                sortBy: [
                    SortDescriptor(\PlaylistEntry.order, order: .forward),
                    SortDescriptor(\PlaylistEntry.dateAdded, order: .forward)
                ]
            )).filter { $0.episode?.url != episodeURL }
            for (index, entry) in entries.enumerated() {
                entry.order = index
            }
        }

        // Unlike saveIfNeeded(), propagate a failed commit. The player must not assume the
        // queue advanced when the finished entry is still persisted.
        if modelContext.hasChanges {
            try modelContext.save()
        }

        // Cross-store propagation and presentation refreshes are not on the audio hand-off
        // path. The local queue commit above is already durable before the successor is used.
        Task { [modelContainer] in
            await self.tombstoneSplitStoreEntries(removals)
            await PlayNextWidgetSync.refresh(
                using: modelContainer,
                playlistIDs: affectedPlaylistIDs
            )
            WatchSyncCoordinator.refreshSoon(force: true)
        }

        return nextEpisodeURL
    }

    func nextEpisode() throws -> URL? {
        try nextEpisodeURL()
    }

    private func currentPlayingEpisodeURL() async -> URL? {
        await MainActor.run {
            Player.shared.currentEpisodeURL
        }
    }

    private func frontInsertionIndex(
        for episodeURL: URL,
        sortedEntries: [PlaylistEntry],
        pinnedEpisodeURL: URL?
    ) -> Int {
        guard pinnedEpisodeURL != nil else { return 0 }
        if pinnedEpisodeURL == episodeURL { return 0 }
        return min(1, sortedEntries.count)
    }

    private func existingEntries(for episodeURL: URL, in playlist: Playlist) -> [PlaylistEntry] {
        playlist.items?.filter { $0.episode?.url == episodeURL } ?? []
    }

    /// Whether an automatic caller must leave this episode out of the playlist.
    private func rejectsAutomaticInsertion(
        _ episode: Episode,
        origin: InsertionOrigin,
        episodeURL: URL,
        playlist: Playlist
    ) -> Bool {
        guard origin == .automatic, episode.isPlayed else { return false }
        logAutoDownload(
            "trigger/auto-add skipped playlist=\(playlist.displayTitle) episode=\(episodeURL.absoluteString) reason=played"
        )
        return true
    }

    /// Stamps the finished episode as completed inside the caller's transaction.
    ///
    /// `Player.finalizeFinishedEpisode` persists the full bookkeeping afterwards,
    /// off the audio hand-off path. Until that lands, every "is this episode still
    /// unplayed?" check would answer yes, and any re-queue racing it would put the
    /// episode back into the queue it was just dequeued from.
    private func markEpisodeFinished(_ episodeURL: URL) throws {
        for episode in try fetchEpisodes(byURL: episodeURL) {
            ensureMetadata(for: episode)
            if episode.metaData?.completionDate == nil {
                episode.metaData?.completionDate = Date()
            }
        }
    }

    private func ensureMetadata(for episode: Episode) {
        guard episode.metaData == nil else { return }
        let metadata = EpisodeMetaData()
        metadata.episode = episode
        episode.metaData = metadata
    }

    private func prepareEpisodesForPlaylistInsertion(_ episodes: [Episode]) {
        for episode in episodes {
            ensureMetadata(for: episode)
            episode.metaData?.setInboxMembership(false)
            episode.metaData?.systemSuppressionReason = nil
            episode.refresh.toggle()
        }
    }

    private func notifyInboxDidChange() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .inboxDidChange, object: nil)
        }
    }

    private func persistLocalEpisodeClassification(
        _ episodes: [Episode]
    ) async {
        let snapshots = episodes.compactMap {
            episode -> StoreSplitLocalEpisodeClassificationSnapshot? in
            guard let metadata = episode.metaData else { return nil }
            return StoreSplitLocalEpisodeClassificationSnapshot(
                identity: episode.stableEpisodeIdentity,
                isInbox: metadata.isInbox == true,
                statusRawValue: metadata.status?.rawValue,
                systemSuppressionReasonRawValue:
                    metadata.systemSuppressionReasonRawValue
            )
        }
        guard snapshots.isEmpty == false else { return }
        await ModelContainerManager.shared.prepareSplitStores()
        guard let cacheContainer = await MainActor.run(body: {
            ModelContainerManager.shared.preparedCacheContainer
        }) else { return }
        await StoreSplitLocalEpisodeClassificationWriter(
            modelContainer: cacheContainer
        ).upsert(snapshots)
    }

    private func startDownloadIfNeeded(for episode: Episode, episodeURL: URL) async {
        guard episode.source != .sideLoaded else { return }
        guard episode.metaData?.calculatedIsAvailableLocally != true else { return }

        let episodeActor = EpisodeActor(modelContainer: modelContainer)
        await episodeActor.download(episodeURL: episodeURL)
    }

    private func restoreQueuedChapterImages(for episodeURL: URL) async {
        let episodeActor = EpisodeActor(modelContainer: modelContainer)
        await episodeActor.restoreFullSizeChapterImages(for: episodeURL)
    }

    private func insertEntry(
        for episode: Episode,
        existingEntry: PlaylistEntry?,
        into playlist: Playlist,
        sortedEntries: inout [PlaylistEntry],
        at targetIndex: Int
    ) {
        if let existingEntry {
            existingEntry.episode = episode
            existingEntry.playlist = playlist
            sortedEntries.insert(existingEntry, at: targetIndex)
        } else {
            let newEntry = PlaylistEntry(episode: episode, order: 0)
            modelContext.insert(newEntry)
            newEntry.playlist = playlist
            sortedEntries.insert(newEntry, at: targetIndex)
        }
    }

    private func detachExistingEntries(
        for episodeURL: URL,
        in playlist: Playlist,
        sortedEntries: inout [PlaylistEntry]
    ) -> PlaylistEntry? {
        let matchingEntries = existingEntries(for: episodeURL, in: playlist)
        let reusableEntry = matchingEntries.first

        for duplicateEntry in matchingEntries.dropFirst() {
            modelContext.delete(duplicateEntry)
        }

        sortedEntries.removeAll { $0.episode?.url == episodeURL }
        return reusableEntry
    }

    func orderedEpisodeSummaries(limit: Int? = nil) throws -> [EpisodeSummary] {
        guard let playlist = try fetchPlaylist() else { return [] }

        let episodes: [Episode]
        if playlist.isSmartPlaylist {
            let ordered = try orderedEpisodes(for: playlist)
            episodes = limit.map { Array(ordered.prefix($0)) } ?? ordered
        } else {
            let orderedEntries = try fetchOrderedEntries()
            let limitedEntries = limit.map { Array(orderedEntries.prefix($0)) } ?? orderedEntries
            episodes = limitedEntries.compactMap { $0.episode }
        }

        return episodes.map { episode in
            EpisodeSummary(
                url: episode.url,
                title: episode.title,
                desc: episode.subtitle ?? episode.desc ?? episode.displayPodcastTitle,
                podcast: episode.displayPodcastTitle,
                cover: episode.imageURL,
                podcastCover: episode.podcast?.imageURL,
                file: episode.url,
                localfile: episode.localFile,
                maxPlayProgress: episode.maxPlayProgress
            )
        }
    }

    func containsEpisodeURL(_ episodeURL: URL) throws -> Bool {
        guard let playlist = try fetchPlaylist() else { return false }
        guard playlist.isSmartPlaylist == false else { return false }
        return existingEntries(for: episodeURL, in: playlist).isEmpty == false
    }
    
    func insert(
        episodeURL: URL,
        after anchorEpisodeURL: URL?,
        startDownload: Bool = true,
        origin: InsertionOrigin = .user
    ) async throws {
        guard let playlist = try fetchPlaylist() else { return }
        guard playlist.isSmartPlaylist == false else { return }
        let matchingEpisodes = try fetchEpisodes(byURL: episodeURL)
        guard let episode = matchingEpisodes.first else { return }
        guard rejectsAutomaticInsertion(
            episode,
            origin: origin,
            episodeURL: episodeURL,
            playlist: playlist
        ) == false else { return }

        var sortedEntries = try fetchOrderedEntries()
        let reusableEntry = detachExistingEntries(
            for: episodeURL,
            in: playlist,
            sortedEntries: &sortedEntries
        )
        
        // 2. Find the anchor's new position after the removal
        if let anchorEpisodeURL,
           let anchorIndex = sortedEntries.firstIndex(where: { $0.episode?.url == anchorEpisodeURL }) {
            // Insert at the position immediately following the anchor
            let targetIndex = anchorIndex + 1
            insertEntry(
                for: episode,
                existingEntry: reusableEntry,
                into: playlist,
                sortedEntries: &sortedEntries,
                at: targetIndex
            )
        } else {
            // Fallback: If no anchor is found, put it at the front (index 0)
            insertEntry(
                for: episode,
                existingEntry: reusableEntry,
                into: playlist,
                sortedEntries: &sortedEntries,
                at: 0
            )
        }
        
        // 3. Re-index and save
        for (i, entry) in sortedEntries.enumerated() {
            entry.order = i
        }
        
        prepareEpisodesForPlaylistInsertion(matchingEpisodes)
        modelContext.saveIfNeeded()
        await persistLocalEpisodeClassification(matchingEpisodes)
        await publishSplitStorePlaylist(playlist)
        await notifyInboxDidChange()
        if startDownload {
            await startDownloadIfNeeded(for: episode, episodeURL: episodeURL)
        }
        await restoreQueuedChapterImages(for: episodeURL)
        await PlayNextWidgetSync.refresh(using: modelContainer, playlistIDs: Set([playlistID]))
        WatchSyncCoordinator.refreshSoon(force: true)
    }

    /// Add/move an episode within the playlist.
    func add(
        episodeURL: URL,
        to position: Playlist.Position = .end,
        startDownload: Bool = true,
        origin: InsertionOrigin = .user
    ) async throws {
        guard let playlist = try fetchPlaylist() else { return }
        guard playlist.isSmartPlaylist == false else { return }
        let matchingEpisodes = try fetchEpisodes(byURL: episodeURL)
        guard let episode = matchingEpisodes.first else { return }
        guard rejectsAutomaticInsertion(
            episode,
            origin: origin,
            episodeURL: episodeURL,
            playlist: playlist
        ) == false else { return }

        // Create a working copy of the ordered entries
        var sortedEntries = try fetchOrderedEntries()
        let pinnedEpisodeURL = await currentPlayingEpisodeURL()

        let reusableEntry = detachExistingEntries(
            for: episodeURL,
            in: playlist,
            sortedEntries: &sortedEntries
        )

        // Determine target insertion index similar to PlaylistViewModel.addEpisode logic
        let targetIndex: Int
        switch position {
        case .front:
            targetIndex = frontInsertionIndex(
                for: episodeURL,
                sortedEntries: sortedEntries,
                pinnedEpisodeURL: pinnedEpisodeURL
            )
        case .end:
            targetIndex = sortedEntries.count
        case .none:
            targetIndex = sortedEntries.count
        }

        insertEntry(
            for: episode,
            existingEntry: reusableEntry,
            into: playlist,
            sortedEntries: &sortedEntries,
            at: targetIndex
        )

        // Reindex to contiguous order values
        for (i, entry) in sortedEntries.enumerated() {
            entry.order = i
        }

        // Update episode metadata
        prepareEpisodesForPlaylistInsertion(matchingEpisodes)

        modelContext.saveIfNeeded()
        await persistLocalEpisodeClassification(matchingEpisodes)
        await publishSplitStorePlaylist(playlist)
        await notifyInboxDidChange()

        if startDownload {
            await startDownloadIfNeeded(for: episode, episodeURL: episodeURL)
        }
        await restoreQueuedChapterImages(for: episodeURL)

        await PlayNextWidgetSync.refresh(using: modelContainer, playlistIDs: Set([playlistID]))
        WatchSyncCoordinator.refreshSoon(force: true)
    }

    /// Add/move an episode with explicit index control within the visual order.
    func add(
        episodeURL: URL,
        to position: Playlist.Position = .end,
        index explicitIndex: Int?,
        startDownload: Bool = true,
        origin: InsertionOrigin = .user
    ) async throws {
        guard let playlist = try fetchPlaylist() else { return }
        guard playlist.isSmartPlaylist == false else { return }
        let matchingEpisodes = try fetchEpisodes(byURL: episodeURL)
        guard let episode = matchingEpisodes.first else { return }
        guard rejectsAutomaticInsertion(
            episode,
            origin: origin,
            episodeURL: episodeURL,
            playlist: playlist
        ) == false else { return }

        var sortedEntries = try fetchOrderedEntries()
        let pinnedEpisodeURL = await currentPlayingEpisodeURL()

        let reusableEntry = detachExistingEntries(
            for: episodeURL,
            in: playlist,
            sortedEntries: &sortedEntries
        )

        let defaultIndex: Int
        switch position {
        case .front:
            defaultIndex = frontInsertionIndex(
                for: episodeURL,
                sortedEntries: sortedEntries,
                pinnedEpisodeURL: pinnedEpisodeURL
            )
        case .end:
            defaultIndex = sortedEntries.count
        case .none:
            defaultIndex = sortedEntries.count
        }

        let targetIndex = max(0, min(explicitIndex ?? defaultIndex, sortedEntries.count))

        insertEntry(
            for: episode,
            existingEntry: reusableEntry,
            into: playlist,
            sortedEntries: &sortedEntries,
            at: targetIndex
        )

        for (i, entry) in sortedEntries.enumerated() {
            entry.order = i
        }

        prepareEpisodesForPlaylistInsertion(matchingEpisodes)

        modelContext.saveIfNeeded()
        await persistLocalEpisodeClassification(matchingEpisodes)
        await publishSplitStorePlaylist(playlist)
        await notifyInboxDidChange()

        if startDownload {
            await startDownloadIfNeeded(for: episode, episodeURL: episodeURL)
        }
        await restoreQueuedChapterImages(for: episodeURL)

        await PlayNextWidgetSync.refresh(using: modelContainer, playlistIDs: Set([playlistID]))
        WatchSyncCoordinator.refreshSoon(force: true)
    }

    func remove(
        episodeURL: URL,
        origin: RemovalOrigin = .user
    ) async throws {
        guard let playlist = try fetchPlaylist() else { return }
        guard playlist.isSmartPlaylist == false else { return }

        let matchingEntries = existingEntries(for: episodeURL, in: playlist)
        let removals = matchingEntries.compactMap { entry -> StoreSplitPlaylistRemoval? in
            guard let identity = entry.episode?.stableEpisodeIdentity else { return nil }
            return StoreSplitPlaylistRemoval(
                playlistID: playlist.storeSplitSyncID,
                isDefaultQueue: playlist.title == Playlist.defaultQueueTitle,
                identity: identity
            )
        }
        logAutoDownload(
            "trigger/manual-remove playlist=\(playlist.displayTitle) episode=\(episodeURL.absoluteString) entries=\(matchingEntries.count) origin=\(String(describing: origin))"
        )

        if matchingEntries.isEmpty == false {
            if origin == .user {
                for episode in matchingEntries.compactMap(\.episode) {
                    ensureMetadata(for: episode)
                    episode.metaData?.systemSuppressionReason = .manualPlaylistRemoval
                }
            }
            for entry in matchingEntries {
                modelContext.delete(entry)
                entry.episode?.refresh.toggle()
            }
            normalizeOrder()
            modelContext.saveIfNeeded()
            await tombstoneSplitStoreEntries(removals)
            Task {
                await PlayNextWidgetSync.refresh(using: modelContainer, playlistIDs: Set([playlistID]))
                WatchSyncCoordinator.refreshSoon(force: true)
            }

            // print("✅ PlaylistEntry deleted and context saved")
        }else{
            logAutoDownload(
                "trigger/manual-remove no-op playlist=\(playlist.displayTitle) episode=\(episodeURL.absoluteString) reason=no-matching-entry"
            )
            // print("No such episode")
        }
    }

    /// Reorders by reindexing .ordered (sorted view) to contiguous 0...n and saves.
    func normalizeOrder()  {
        do{
            guard let playlist = try? fetchPlaylist() else { return }
            guard playlist.isSmartPlaylist == false else { return }
            for (i, entry) in try fetchOrderedEntries().enumerated() {
                entry.order = i
            }
            modelContext.saveIfNeeded()
        }catch{
            
        }
    }

    /// Move an entry by source/destination indices as seen in sorted order.
    func moveEntry(from sourceIndex: Int, to destinationIndex: Int) async throws {
        guard let playlist = try fetchPlaylist() else { return }
        guard playlist.isSmartPlaylist == false else { return }
        print("move from \(sourceIndex) to \(destinationIndex)")
        if let sorted = playlist.items?.sorted(by: { $0.order < $1.order }){
            guard sourceIndex < sorted.count, destinationIndex <= sorted.count else { return }

            var reordered = sorted
            let moved = reordered.remove(at: sourceIndex)
            let adjustedDestination = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
            let safeDestination = max(0, min(adjustedDestination, reordered.count))
            reordered.insert(moved, at: safeDestination)
            
            for (i, entry) in reordered.enumerated() {
                entry.order = i
            }
            normalizeOrder()
            await publishSplitStorePlaylist(playlist)
            Task {
                await PlayNextWidgetSync.refresh(using: modelContainer, playlistIDs: Set([playlistID]))
                WatchSyncCoordinator.refreshSoon(force: true)
            }
        }
    }

    func removeFromAllPlaylists(episodeURL: URL) async throws {
        let descriptor = FetchDescriptor<PlaylistEntry>(
            predicate: #Predicate<PlaylistEntry> { entry in
                entry.episode?.url == episodeURL
            }
        )

        let entries = try modelContext.fetch(descriptor)
        guard entries.isEmpty == false else { return }

        let playlists = Set(entries.compactMap { $0.playlist?.id })
        let removals = entries.compactMap { entry -> StoreSplitPlaylistRemoval? in
            guard let playlist = entry.playlist,
                  let identity = entry.episode?.stableEpisodeIdentity else {
                return nil
            }
            return StoreSplitPlaylistRemoval(
                playlistID: playlist.storeSplitSyncID,
                isDefaultQueue: playlist.title == Playlist.defaultQueueTitle,
                identity: identity
            )
        }

        for entry in entries {
            modelContext.delete(entry)
            entry.episode?.refresh.toggle()
        }

        for playlistID in playlists {
            let playlistDescriptor = FetchDescriptor<Playlist>(
                predicate: #Predicate<Playlist> { $0.id == playlistID }
            )
            if let playlist = try modelContext.fetch(playlistDescriptor).first, playlist.isSmartPlaylist == false {
                for (index, entry) in try fetchOrderedEntries().enumerated() {
                    entry.order = index
                }
            }
        }

        modelContext.saveIfNeeded()
        await tombstoneSplitStoreEntries(removals)

        Task {
            await PlayNextWidgetSync.refresh(using: modelContainer, playlistIDs: playlists)
            WatchSyncCoordinator.refreshSoon(force: true)
        }
    }

    private func tombstoneSplitStoreEntries(_ removals: [StoreSplitPlaylistRemoval]) async {
        guard removals.isEmpty == false else { return }
        await ModelContainerManager.shared.prepareSplitStores()
        guard let userStateContainer = await MainActor.run(body: {
            ModelContainerManager.shared.preparedUserStateContainer
        }) else {
            CrashBreadcrumbs.shared.record(
                "store_split_playlist_tombstone_deferred",
                details: "count=\(removals.count)"
            )
            return
        }

        let writer = StoreSplitPlaylistSyncWriter(modelContainer: userStateContainer)
        await writer.tombstone(removals)
    }

    private func publishSplitStorePlaylist(_ playlist: Playlist) async {
        guard playlist.isSmartPlaylist == false else { return }
        let snapshot = playlist.storeSplitSnapshot

        await ModelContainerManager.shared.prepareSplitStores()
        guard let userStateContainer = await MainActor.run(body: {
            ModelContainerManager.shared.preparedUserStateContainer
        }) else { return }
        await StoreSplitPlaylistSyncWriter(modelContainer: userStateContainer)
            .upsert(snapshot)
    }

    // MARK: - Convenience helpers callable from outside

    func fetchEpisodeByURL(_ url: URL) throws -> Episode? { try fetchEpisode(byURL: url) }
}
