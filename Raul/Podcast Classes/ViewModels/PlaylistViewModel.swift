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

    private let actor: PlaylistModelActor?
    private let playlistTitle: String
    private let context: ModelContext


    
    init (playlistTitle: String = "de.holgerkrupp.podbay.queue", container: ModelContainer) {
        self.playlistTitle = playlistTitle
        self.context = ModelContext(container)
        self.actor = try? PlaylistModelActor(modelContainer: container)
        
        Task {
            await loadEntries()
        }
    }


    func loadEntries() async {
        let localplaylistTitle = playlistTitle
        let descriptor = FetchDescriptor<PlaylistEntry>(
            predicate: #Predicate { entry in
                entry.playlist?.title == localplaylistTitle
            },
            sortBy: [SortDescriptor(\.order, order: .forward)]
        )
        do {
            let result = try context.fetch(descriptor)
            self.entries = result
        } catch {
            print("Failed to fetch entries: \(error)")
        }
    }

    func addEpisode(_ episode: Episode, to position: Playlist.Position = .end) async {
        guard let actor = actor else {
            print("PlaylistModelActor not available")
            return
        }
        try? await actor.add(episodeID: episode.id, to: position)
        await loadEntries()
    }

    func removeEpisode(_ episode: Episode) async {
        guard let actor = actor else {
            print("PlaylistModelActor not available")
            return
        }
        try? await actor.remove(episodeID: episode.id)
        await loadEntries()
    }

    func moveEntry(from source: Int, to destination: Int) async {
        guard let actor = actor else {
            print("PlaylistModelActor not available")
            return
        }
        try? await actor.moveEntry(from: source, to: destination)
        await loadEntries()
    }

    func normalizeOrder() async {
        guard let actor = actor else {
            print("PlaylistModelActor not available")
            return
        }
        try? await actor.normalizeOrder()
        await loadEntries()
    }
}

