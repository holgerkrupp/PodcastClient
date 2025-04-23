//
//  PlaylistActor.swift
//  Raul
//
//  Created by Holger Krupp on 23.04.25.
//
import SwiftData
import Foundation




//@ModelActor
actor PlaylistModelActor : ModelActor {
    let playlistID: PersistentIdentifier

    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor
    
    public init(modelContainer: ModelContainer, playlistID: PersistentIdentifier) {
      let modelContext = ModelContext(modelContainer)
      modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
      self.modelContainer = modelContainer
        self.playlistID = playlistID
    }
    
  

    // Add an episode to the playlist
    func add(episodeID: PersistentIdentifier, to position: Playlist.Position = .end) async {
        guard let playlist = modelContext.model(for: playlistID) as? Playlist,
              let episode = modelContext.model(for: episodeID) as? Episode else {
            return
        }

        if episode.metaData?.isAvailableLocally != true {
            if let localFile = episode.localFile {
                let url = episode.url
                let manager = DownloadManager.shared
                episode.downloadItem = await manager.download(from: url, saveTo: localFile)
            }
        }

        var newPosition = 0
        switch position {
        case .front:
            newPosition = (playlist.ordered.first?.order ?? 0) - 1
        case .end:
            newPosition = (playlist.ordered.last?.order ?? 0) + 1
        case .none:
            newPosition = (playlist.ordered.last?.order ?? 0)
        }

        if let existingItem = playlist.items?.first(where: { $0.episode == episode }) {
            existingItem.order = newPosition
        } else {
            let newEntry = PlaylistEntry(episode: episode, order: newPosition)
            if playlist.items == nil {
                playlist.items = [newEntry]
            } else {
                playlist.items?.append(newEntry)
            }
        }

        try? modelContext.save()
    }

    // Remove an episode from the playlist
    func remove(episodeID: PersistentIdentifier) {
        guard let playlist = modelContext.model(for: playlistID) as? Playlist,
              let episode = modelContext.model(for: episodeID) as? Episode,
              let entry = playlist.items?.first(where: { $0.episode == episode }) else {
            return
        }

        if let index = playlist.items?.firstIndex(of: entry) {
            playlist.items?.remove(at: index)
            modelContext.delete(entry)
        }

        try? modelContext.save()
    }

    // Reorder playlist entries
    func moveEntry(from sourceIndex: Int, to destinationIndex: Int) {
        guard let playlist = modelContext.model(for: playlistID) as? Playlist,
              var entries = playlist.items else {
            return
        }

        let sorted = entries.sorted { $0.order < $1.order }

        guard sourceIndex < sorted.count, destinationIndex < sorted.count else { return }

        let movedEntry = sorted[sourceIndex]
        var reordered = sorted
        reordered.remove(at: sourceIndex)
        reordered.insert(movedEntry, at: destinationIndex)

        for (i, entry) in reordered.enumerated() {
            entry.order = i
        }

        try? modelContext.save()
    }
    
    func normalizeOrder() {
        guard let playlist = modelContext.model(for: playlistID) as? Playlist else { return }

        for (i, entry) in (playlist.ordered).enumerated() {
            entry.order = i
        }

        try? modelContext.save()
    }
}
