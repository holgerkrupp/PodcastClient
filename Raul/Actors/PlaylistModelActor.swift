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
        // Prefer a shared container if you have one; fall back to provided or new
        let container = modelContainer ?? (ModelContainerManager().container ?? ModelContainerManager().container!)
        self.modelContainer = container
        self.modelContext = ModelContext(container)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
        self.playlistID = playlistID

       
    }

    /// Initialize by title; creates the playlist if it doesn't exist.
    public init(modelContainer: ModelContainer? = nil,
                playlistTitle: String = "de.holgerkrupp.podbay.queue") throws {
        let container = modelContainer ?? (ModelContainerManager().container ?? ModelContainerManager().container!)
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
        let predicate = #Predicate<Episode> { $0.id == episodeID }
        return try modelContext.fetch(FetchDescriptor<Episode>(predicate: predicate)).first
    }

    private func fetchEpisode(byURL fileURL: URL) throws -> Episode? {
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
        return p
    }

    func orderedEpisodes() throws -> [Episode] {
        guard let playlist = try fetchPlaylist() else { return [] }
        return playlist.ordered.compactMap { $0.episode }
    }

    func nextEpisode() throws -> UUID? {
        try orderedEpisodes().first?.id
    }

    func orderedEpisodeSummaries() throws -> [EpisodeSummary] {
        try orderedEpisodes().map { episode in
            EpisodeSummary(
                id: episode.id,
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

    /// Add/move an episode within the playlist.
    func add(episodeID: UUID, to position: Playlist.Position = .end) async throws {
        guard let playlist = try fetchPlaylist(),
              let episode = try fetchEpisode(byID: episodeID) else { return }

        await BasicLogger.shared.log("🎯 Adding episode \(episode.title) to playlist \(playlist.title) at position \(position) - \(episode.id)")

        // Compute new order anchor
        let newPosition: Int
        switch position {
        case .front:
            newPosition = (playlist.ordered.first?.order ?? 0) - 1
        case .end:
            newPosition = (playlist.ordered.last?.order ?? 0) + 1
        case .none:
            newPosition = (playlist.ordered.last?.order ?? 0)
        }

        // Update if exists; otherwise create entry and link
        if let existingItem = playlist.items.first(where: { $0.episode?.id == episode.id }) {
            existingItem.order = newPosition
            await BasicLogger.shared.log("🔄 Moved existing entry to \(newPosition)")
        } else {
            let newEntry = PlaylistEntry(episode: episode, order: newPosition)
            modelContext.insert(newEntry)
            newEntry.playlist = playlist
            episode.playlist.append(newEntry)
            await BasicLogger.shared.log("➕ Created PlaylistEntry at \(newPosition) for \(playlist.title)")
        }

        // Update episode metadata
        episode.metaData?.isInbox = false
        episode.metaData?.isArchived = false
        episode.metaData?.status = .none
        episode.refresh.toggle()

        try normalizeOrder() // will save
        await BasicLogger.shared.log("✅ Saved playlist changes")

        if episode.metaData?.calculatedIsAvailableLocally != true {
            let episodeActor = EpisodeActor(modelContainer: self.modelContainer)
            await episodeActor.download(episodeID: episode.id)
        }
    }

    func remove(episodeID: UUID) throws {
        guard let playlist = try fetchPlaylist() else { return }
        
        if let entry = playlist.items.first(where: { $0.episode?.id == episodeID }){
            
            modelContext.delete(entry)
            entry.episode?.refresh.toggle()
            try modelContext.save()
            print("✅ PlaylistEntry deleted and context saved")
        }else{
            print("No such episode")
        }
    }

    /// Reorders by reindexing .ordered (sorted view) to contiguous 0...n and saves.
    func normalizeOrder() throws {
        guard let playlist = try fetchPlaylist() else { return }
        for (i, entry) in playlist.ordered.enumerated() {
            entry.order = i
        }
        try modelContext.save()
    }

    /// Move an entry by source/destination indices as seen in sorted order.
    func moveEntry(from sourceIndex: Int, to destinationIndex: Int) throws {
        guard let playlist = try fetchPlaylist() else { return }

        let sorted = playlist.items.sorted { $0.order < $1.order }
        guard sourceIndex < sorted.count, destinationIndex < sorted.count else { return }

        let moved = sorted[sourceIndex]
        var reordered = sorted
        reordered.remove(at: sourceIndex)
        reordered.insert(moved, at: destinationIndex)

        for (i, entry) in reordered.enumerated() {
            entry.order = i
        }
        try modelContext.save()
    }

    // MARK: - Convenience helpers callable from outside

    func fetchEpisodeByID(_ id: UUID) throws -> Episode? { try fetchEpisode(byID: id) }
    func fetchEpisodeByURL(_ url: URL) throws -> Episode? { try fetchEpisode(byURL: url) }
}

// MARK: - Sendable summary value
struct EpisodeSummary: Sendable {
    let id: UUID
    let title: String?
    let desc: String?
    let podcast: String?
    let cover: URL?
    let podcastCover: URL?
    let file: URL?
    let localfile: URL?
}
