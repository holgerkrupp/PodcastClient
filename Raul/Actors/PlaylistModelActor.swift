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

        return playlist.ordered.compactMap { $0.episode }
    }

    func orderedEpisodes() throws -> [Episode] {
        guard let playlist = try fetchPlaylist() else { return [] }
        return try orderedEpisodes(for: playlist)
    }

    public func orderedEpisodeURLs() throws -> [URL] {
        try orderedEpisodes().compactMap(\.url)
    }

    func nextEpisodeURL() throws -> URL? {
        try orderedEpisodes().dropFirst().compactMap(\.url).first
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

    private func ensureMetadata(for episode: Episode) {
        guard episode.metaData == nil else { return }
        let metadata = EpisodeMetaData()
        metadata.episode = episode
        episode.metaData = metadata
    }

    private func updateQueuedEpisodeMetadata(_ episodes: [Episode]) {
        for episode in episodes {
            ensureMetadata(for: episode)
            episode.metaData?.isInbox = false
            episode.metaData?.isArchived = false
            episode.metaData?.status = nil
            episode.metaData?.archivedAt = nil
            episode.metaData?.systemSuppressionReason = nil
            episode.refresh.toggle()
        }
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

    private func notifyInboxDidChange() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .inboxDidChange, object: nil)
        }
    }

    func orderedEpisodeSummaries() throws -> [EpisodeSummary] {
        try orderedEpisodes().map { episode in
            EpisodeSummary(
                url: episode.url,
                title: episode.title,
                desc: episode.subtitle ?? episode.desc ?? episode.displayPodcastTitle,
                podcast: episode.displayPodcastTitle,
                cover: episode.imageURL,
                podcastCover: episode.podcast?.imageURL,
                file: episode.url,
                localfile: episode.localFile
            )
        }
    }

    func containsEpisodeURL(_ episodeURL: URL) throws -> Bool {
        guard let playlist = try fetchPlaylist() else { return false }
        guard playlist.isSmartPlaylist == false else { return false }
        return existingEntries(for: episodeURL, in: playlist).isEmpty == false
    }
    
    func insert(episodeURL: URL, after anchorEpisodeURL: URL?, startDownload: Bool = true) async throws {
        guard let playlist = try fetchPlaylist() else { return }
        guard playlist.isSmartPlaylist == false else { return }
        let matchingEpisodes = try fetchEpisodes(byURL: episodeURL)
        guard let episode = matchingEpisodes.first else { return }

        var sortedEntries = playlist.ordered
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
        
        updateQueuedEpisodeMetadata(matchingEpisodes)
        modelContext.saveIfNeeded()
        await notifyInboxDidChange()
        if startDownload {
            await startDownloadIfNeeded(for: episode, episodeURL: episodeURL)
        }
        await restoreQueuedChapterImages(for: episodeURL)
        await PlayNextWidgetSync.refresh(using: modelContainer, playlistIDs: Set([playlistID]))
        WatchSyncCoordinator.refreshSoon()
    }

    /// Add/move an episode within the playlist.
    func add(episodeURL: URL, to position: Playlist.Position = .end, startDownload: Bool = true) async throws {
        guard let playlist = try fetchPlaylist() else { return }
        guard playlist.isSmartPlaylist == false else { return }
        let matchingEpisodes = try fetchEpisodes(byURL: episodeURL)
        guard let episode = matchingEpisodes.first else { return }

        // Create a working copy of the ordered entries
        var sortedEntries = playlist.ordered
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
        updateQueuedEpisodeMetadata(matchingEpisodes)

        modelContext.saveIfNeeded()
        await notifyInboxDidChange()

        if startDownload {
            await startDownloadIfNeeded(for: episode, episodeURL: episodeURL)
        }
        await restoreQueuedChapterImages(for: episodeURL)

        await PlayNextWidgetSync.refresh(using: modelContainer, playlistIDs: Set([playlistID]))
        WatchSyncCoordinator.refreshSoon()
    }

    /// Add/move an episode with explicit index control within the visual order.
    func add(episodeURL: URL, to position: Playlist.Position = .end, index explicitIndex: Int?, startDownload: Bool = true) async throws {
        guard let playlist = try fetchPlaylist() else { return }
        guard playlist.isSmartPlaylist == false else { return }
        let matchingEpisodes = try fetchEpisodes(byURL: episodeURL)
        guard let episode = matchingEpisodes.first else { return }

        var sortedEntries = playlist.ordered
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

        updateQueuedEpisodeMetadata(matchingEpisodes)

        modelContext.saveIfNeeded()
        await notifyInboxDidChange()

        if startDownload {
            await startDownloadIfNeeded(for: episode, episodeURL: episodeURL)
        }
        await restoreQueuedChapterImages(for: episodeURL)

        await PlayNextWidgetSync.refresh(using: modelContainer, playlistIDs: Set([playlistID]))
        WatchSyncCoordinator.refreshSoon()
    }

    func remove(episodeURL: URL, triggerAutoDownload: Bool = true) throws {
        guard let playlist = try fetchPlaylist() else { return }
        guard playlist.isSmartPlaylist == false else { return }

        let matchingEntries = existingEntries(for: episodeURL, in: playlist)
        let affectedPodcastFeeds = Set(matchingEntries.compactMap { $0.episode?.podcast?.feed })
        logAutoDownload(
            "trigger/manual-remove playlist=\(playlist.displayTitle) episode=\(episodeURL.absoluteString) entries=\(matchingEntries.count) affectedFeeds=\(affectedPodcastFeeds.count)"
        )

        if matchingEntries.isEmpty == false {
            for entry in matchingEntries {
                modelContext.delete(entry)
                entry.episode?.refresh.toggle()
            }
            normalizeOrder()
            modelContext.saveIfNeeded()
            Task {
                await PlayNextWidgetSync.refresh(using: modelContainer, playlistIDs: Set([playlistID]))
                WatchSyncCoordinator.refreshSoon()
            }

            if triggerAutoDownload && affectedPodcastFeeds.isEmpty == false {
                let container = modelContainer
                Task {
                    let episodeActor = EpisodeActor(modelContainer: container)
                    for podcastFeed in affectedPodcastFeeds {
                        await MainActor.run {
                            BasicLogger.shared.log("[AutoDL] trigger/manual-remove applying-policy feed=\(podcastFeed.absoluteString)")
                        }
                        await episodeActor.applyAutomaticDownloadPolicy(for: podcastFeed)
                    }
                }
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
        guard let playlist = try? fetchPlaylist() else { return }
        guard playlist.isSmartPlaylist == false else { return }
        for (i, entry) in playlist.ordered.enumerated() {
            entry.order = i
        }
        modelContext.saveIfNeeded()
    }

    /// Move an entry by source/destination indices as seen in sorted order.
    func moveEntry(from sourceIndex: Int, to destinationIndex: Int) throws {
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
            Task {
                await PlayNextWidgetSync.refresh(using: modelContainer, playlistIDs: Set([playlistID]))
                WatchSyncCoordinator.refreshSoon()
            }
        }
    }

    func removeFromAllPlaylists(episodeURL: URL) throws {
        let descriptor = FetchDescriptor<PlaylistEntry>(
            predicate: #Predicate<PlaylistEntry> { entry in
                entry.episode?.url == episodeURL
            }
        )

        let entries = try modelContext.fetch(descriptor)
        guard entries.isEmpty == false else { return }

        let playlists = Set(entries.compactMap { $0.playlist?.id })

        for entry in entries {
            modelContext.delete(entry)
            entry.episode?.refresh.toggle()
        }

        for playlistID in playlists {
            let playlistDescriptor = FetchDescriptor<Playlist>(
                predicate: #Predicate<Playlist> { $0.id == playlistID }
            )
            if let playlist = try modelContext.fetch(playlistDescriptor).first, playlist.isSmartPlaylist == false {
                for (index, entry) in playlist.ordered.enumerated() {
                    entry.order = index
                }
            }
        }

        modelContext.saveIfNeeded()

        Task {
            await PlayNextWidgetSync.refresh(using: modelContainer, playlistIDs: playlists)
            WatchSyncCoordinator.refreshSoon()
        }
    }

    // MARK: - Convenience helpers callable from outside

    func fetchEpisodeByURL(_ url: URL) throws -> Episode? { try fetchEpisode(byURL: url) }
}
