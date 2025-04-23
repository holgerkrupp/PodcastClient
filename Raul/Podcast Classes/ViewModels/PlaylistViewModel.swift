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
    private let actor: PlaylistModelActor
    private let playlistID: PersistentIdentifier

    init(playlist: Playlist, container: ModelContainer) {
        self.playlistID = playlist.persistentModelID
        self.actor = PlaylistModelActor(modelContainer: container, playlistID: playlistID)
    }

    func addEpisode(_ episode: Episode, to position: Playlist.Position = .end) async {
        await actor.add(episodeID: episode.persistentModelID, to: position)
    }

    func removeEpisode(_ episode: Episode) async {
        await actor.remove(episodeID: episode.persistentModelID)
    }

    func moveEntry(from source: Int, to destination: Int) async {
        await actor.moveEntry(from: source, to: destination)
    }

    func normalizeOrder() async {
        await actor.normalizeOrder()
    }
}
