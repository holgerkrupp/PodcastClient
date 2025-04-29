//
//  PlaylistViewModel.swift
//  Raul
//
//  Created by Holger Krupp on 23.04.25.
//

import SwiftUI
import SwiftData

@MainActor
class PlaylistViewModel: ObservableObject {
    @Published var entries: [PlaylistEntry] = []

    private let actor: PlaylistModelActor
    private let playlistID: UUID
    private let context: ModelContext

    init(playlist: Playlist, container: ModelContainer) {
        self.playlistID = playlist.id
        self.context = ModelContext(container)
        self.actor = PlaylistModelActor(modelContainer: container, playlistID: playlistID)

        Task {
            await loadEntries()
        }
    }
    
    init (playlistID: UUID, container: ModelContainer) {
        self.playlistID = playlistID
        self.context = ModelContext(container)
        self.actor = PlaylistModelActor(modelContainer: container, playlistID: playlistID)
        
        Task {
            await loadEntries()
        }
    }
    


    func loadEntries() async {
        let localPlaylistID = playlistID
        let descriptor = FetchDescriptor<PlaylistEntry>(
            predicate: #Predicate { entry in
                entry.playlist?.id == localPlaylistID
            },
            sortBy: [SortDescriptor(\.order, order: .forward)]
        )
        do {
            let result = try context.fetch(descriptor)
            print("Fetched \(result.count) playlist entries")
            self.entries = result
        } catch {
            print("Failed to fetch entries: \(error)")
        }
    }

    func addEpisode(_ episode: Episode, to position: Playlist.Position = .end) async {
        await actor.add(episodeID: episode.id, to: position)
        await loadEntries()
    }

    func removeEpisode(_ episode: Episode) async {
        await actor.remove(episodeID: episode.id)
        await loadEntries()
    }

    func moveEntry(from source: Int, to destination: Int) async {
        await actor.moveEntry(from: source, to: destination)
        await loadEntries()
    }

    func normalizeOrder() async {
        await actor.normalizeOrder()
        await loadEntries()
    }
}
