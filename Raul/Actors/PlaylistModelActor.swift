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

       
    }

    /// Initialize by title; creates the playlist if it doesn't exist.
    public init(modelContainer: ModelContainer? = nil,
                playlistTitle: String = "de.holgerkrupp.podbay.queue") throws {
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
            modelContext.insert(newPlaylist)
            try modelContext.save()
            self.playlistID = newPlaylist.id
        }
        
    }

    // MARK: - Private helpers

    /// Always fetch the current playlist in this actor’s context.
    private func fetchPlaylist() throws -> Playlist? {

        let predicate = #Predicate<Playlist> { $0.id == playlistID }
        let descriptor = FetchDescriptor<Playlist>(predicate: predicate)
        return try modelContext.fetch(descriptor).first
    }

    private func fetchEpisode(byID episodeID: UUID) throws -> Episode? {
        normalizeOrder() // will save

        let predicate = #Predicate<Episode> { $0.id == episodeID }
        return try modelContext.fetch(FetchDescriptor<Episode>(predicate: predicate)).first
    }

    private func fetchEpisode(byURL fileURL: URL) throws -> Episode? {
        normalizeOrder() // will save

        let predicate = #Predicate<Episode> { $0.url == fileURL }
        return try modelContext.fetch(FetchDescriptor<Episode>(predicate: predicate)).first
    }

    // MARK: - Public API (safe)

    /// Re-fetches and returns the up-to-date playlist. Useful if callers want to verify presence.
    @discardableResult
    func refresh() throws -> Playlist {
        guard let p = try fetchPlaylist() else {
            throw NSError(domain: "PlaylistModelActor", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Playlist not found during refresh"])
        }
        normalizeOrder() // will save

        return p
    }

    func orderedEpisodes() throws -> [Episode] {
        guard let playlist = try fetchPlaylist() else { return [] }
        normalizeOrder() // will save

        return playlist.ordered.compactMap { $0.episode }
    }

    /// Returns the IDs of episodes in playlist order (Sendable).
    public func orderedEpisodeIDs() throws -> [UUID] {
        return try orderedEpisodes().map { $0.id }
    }

    func nextEpisode() throws -> URL? {
        normalizeOrder() // will save
        
        return try orderedEpisodes().dropFirst().first?.url
    }

    private func currentPlayingEpisodeID() async -> UUID? {
        await MainActor.run {
            Player.shared.currentEpisodeID
        }
    }

    private func frontInsertionIndex(
        for episodeID: UUID,
        sortedEntries: [PlaylistEntry],
        pinnedEpisodeID: UUID?
    ) -> Int {
        guard pinnedEpisodeID != nil else { return 0 }
        if pinnedEpisodeID == episodeID { return 0 }
        return min(1, sortedEntries.count)
    }

    func orderedEpisodeSummaries() throws -> [EpisodeSummary] {
        try orderedEpisodes().map { episode in
            EpisodeSummary(
                id: episode.id,
                url: episode.url,
                title: episode.title,
                desc: episode.subtitle ?? episode.desc ?? episode.podcast?.title,
                podcast: episode.podcast?.title,
                cover: episode.imageURL,
                podcastCover: episode.podcast?.imageURL,
                file: episode.url,
                localfile: episode.localFile
            )
        }
    }
    
 
    /// Inserts an episode specifically after another episode (the anchor).
    func insert(episodeID: UUID, after anchorEpisodeID: UUID?) throws {
        guard let playlist = try fetchPlaylist(),
              let episode = try fetchEpisode(byID: episodeID) else { return }

        var sortedEntries = playlist.ordered
        
        // 1. Remove the item if it's already there (to prevent duplicates/shifts)
        if let existingIndex = sortedEntries.firstIndex(where: { $0.episode?.id == episodeID }) {
            sortedEntries.remove(at: existingIndex)
        }
        
        // 2. Find the anchor's new position after the removal
        if let anchorID = anchorEpisodeID,
           let anchorIndex = sortedEntries.firstIndex(where: { $0.episode?.id == anchorID }) {
            // Insert at the position immediately following the anchor
            let targetIndex = anchorIndex + 1
            
            if let existingEntry = playlist.items?.first(where: { $0.episode?.id == episodeID }) {
                sortedEntries.insert(existingEntry, at: targetIndex)
            } else {
                let newEntry = PlaylistEntry(episode: episode, order: 0)
                modelContext.insert(newEntry)
                newEntry.playlist = playlist
                sortedEntries.insert(newEntry, at: targetIndex)
            }
        } else {
            // Fallback: If no anchor is found, put it at the front (index 0)
            if let existingEntry = playlist.items?.first(where: { $0.episode?.id == episodeID }) {
                sortedEntries.insert(existingEntry, at: 0)
            } else {
                let newEntry = PlaylistEntry(episode: episode, order: 0)
                modelContext.insert(newEntry)
                newEntry.playlist = playlist
                sortedEntries.insert(newEntry, at: 0)
            }
        }
        
        // 3. Re-index and save
        for (i, entry) in sortedEntries.enumerated() {
            entry.order = i
        }
        
        episode.metaData?.isInbox = false
        episode.refresh.toggle()
        modelContext.saveIfNeeded()
        Task {
            await PlayNextWidgetSync.refresh(using: modelContainer)
        }
    }

    /// Add/move an episode within the playlist.
    func add(episodeID: UUID, to position: Playlist.Position = .end) async throws {
        guard let playlist = try fetchPlaylist(),
              let episode = try fetchEpisode(byID: episodeID) else { return }

        // Create a working copy of the ordered entries
        var sortedEntries = playlist.ordered
        let pinnedEpisodeID = await currentPlayingEpisodeID()

        // Remove existing entry if present to avoid duplicates and position drift
        if let existingIndex = sortedEntries.firstIndex(where: { $0.episode?.id == episodeID }) {
            sortedEntries.remove(at: existingIndex)
        }

        // Determine target insertion index similar to PlaylistViewModel.addEpisode logic
        let targetIndex: Int
        switch position {
        case .front:
            targetIndex = frontInsertionIndex(
                for: episodeID,
                sortedEntries: sortedEntries,
                pinnedEpisodeID: pinnedEpisodeID
            )
        case .end:
            targetIndex = sortedEntries.count
        case .none:
            targetIndex = sortedEntries.count
        }

        // Reuse existing entry if it exists in the playlist items, otherwise create
        if let existingEntry = playlist.items?.first(where: { $0.episode?.id == episodeID }) {
            // Ensure it's detached from previous position: it was removed from sortedEntries above
            sortedEntries.insert(existingEntry, at: targetIndex)
        } else {
            let newEntry = PlaylistEntry(episode: episode, order: 0)
            modelContext.insert(newEntry)
            newEntry.playlist = playlist
            sortedEntries.insert(newEntry, at: targetIndex)
        }

        // Reindex to contiguous order values
        for (i, entry) in sortedEntries.enumerated() {
            entry.order = i
        }

        // Update episode metadata
        episode.metaData?.isInbox = false
        episode.metaData?.isArchived = false
        episode.metaData?.status = .none
        episode.refresh.toggle()

        modelContext.saveIfNeeded()

        // Trigger download if not available locally
        if episode.metaData?.calculatedIsAvailableLocally != true {
            let episodeActor = EpisodeActor(modelContainer: self.modelContainer)
            await episodeActor.download(episodeID: episode.id)
        }

        await PlayNextWidgetSync.refresh(using: modelContainer)
    }

    /// Add/move an episode with explicit index control within the visual order.
    func add(episodeID: UUID, to position: Playlist.Position = .end, index explicitIndex: Int?) async throws {
        guard let playlist = try fetchPlaylist(),
              let episode = try fetchEpisode(byID: episodeID) else { return }

        var sortedEntries = playlist.ordered
        let pinnedEpisodeID = await currentPlayingEpisodeID()

        if let existingIndex = sortedEntries.firstIndex(where: { $0.episode?.id == episodeID }) {
            sortedEntries.remove(at: existingIndex)
        }

        let defaultIndex: Int
        switch position {
        case .front:
            defaultIndex = frontInsertionIndex(
                for: episodeID,
                sortedEntries: sortedEntries,
                pinnedEpisodeID: pinnedEpisodeID
            )
        case .end:
            defaultIndex = sortedEntries.count
        case .none:
            defaultIndex = sortedEntries.count
        }

        let targetIndex = max(0, min(explicitIndex ?? defaultIndex, sortedEntries.count))

        if let existingEntry = playlist.items?.first(where: { $0.episode?.id == episodeID }) {
            sortedEntries.insert(existingEntry, at: targetIndex)
        } else {
            let newEntry = PlaylistEntry(episode: episode, order: 0)
            modelContext.insert(newEntry)
            newEntry.playlist = playlist
            sortedEntries.insert(newEntry, at: targetIndex)
        }

        for (i, entry) in sortedEntries.enumerated() {
            entry.order = i
        }

        episode.metaData?.isInbox = false
        episode.metaData?.isArchived = false
        episode.metaData?.status = .none
        episode.refresh.toggle()

        modelContext.saveIfNeeded()

        if episode.metaData?.calculatedIsAvailableLocally != true {
            let episodeActor = EpisodeActor(modelContainer: self.modelContainer)
            await episodeActor.download(episodeID: episode.id)
        }

        await PlayNextWidgetSync.refresh(using: modelContainer)
    }

    func remove(episodeID: UUID) throws {
        guard let playlist = try fetchPlaylist() else { return }
        
        if let entry = playlist.items?.first(where: { $0.episode?.id == episodeID }){
            
            modelContext.delete(entry)
            normalizeOrder()
            entry.episode?.refresh.toggle()
            modelContext.saveIfNeeded()
            Task {
                await PlayNextWidgetSync.refresh(using: modelContainer)
            }
            // print("✅ PlaylistEntry deleted and context saved")
        }else{
            // print("No such episode")
        }
    }
    
    func remove(episodeURL: URL) throws {
        guard let playlist = try fetchPlaylist() else { return }
        
        if let entry = playlist.items?.first(where: { $0.episode?.url == episodeURL }){
            
            modelContext.delete(entry)
            normalizeOrder()
            entry.episode?.refresh.toggle()
            modelContext.saveIfNeeded()
            Task {
                await PlayNextWidgetSync.refresh(using: modelContainer)
            }
            // print("✅ PlaylistEntry deleted and context saved")
        }else{
            // print("No such episode")
        }
    }

    /// Reorders by reindexing .ordered (sorted view) to contiguous 0...n and saves.
    func normalizeOrder()  {
        guard let playlist = try? fetchPlaylist() else { return }
        for (i, entry) in playlist.ordered.enumerated() {
            entry.order = i
        }
        modelContext.saveIfNeeded()
    }

    /// Move an entry by source/destination indices as seen in sorted order.
    func moveEntry(from sourceIndex: Int, to destinationIndex: Int) throws {
        guard let playlist = try fetchPlaylist() else { return }
        print("move from \(sourceIndex) to \(destinationIndex)")
        if let sorted = playlist.items?.sorted(by: { $0.order < $1.order }){
            guard sourceIndex < sorted.count, destinationIndex < sorted.count else { return }
            
            let moved = sorted[sourceIndex]
            var reordered = sorted
            reordered.remove(at: sourceIndex)
            reordered.insert(moved, at: destinationIndex)
            
            for (i, entry) in reordered.enumerated() {
                entry.order = i
            }
            normalizeOrder()
            Task {
                await PlayNextWidgetSync.refresh(using: modelContainer)
            }
        }
    }

    // MARK: - Convenience helpers callable from outside

    func fetchEpisodeByID(_ id: UUID) throws -> Episode? { try fetchEpisode(byID: id) }
    func fetchEpisodeByURL(_ url: URL) throws -> Episode? { try fetchEpisode(byURL: url) }
}
