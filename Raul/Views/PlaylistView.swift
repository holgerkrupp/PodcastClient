//
//  PlaylistView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//



import SwiftUI
import SwiftData

struct PlaylistView: View {
    @StateObject private var viewModel: PlaylistViewModel
    @Query private var entries: [PlaylistEntry]
    private var playlistname: String
    
    init(playlist: Playlist, container: ModelContainer) {
        playlistname = playlist.title
        _viewModel = StateObject(wrappedValue: PlaylistViewModel(playlist: playlist, container: container))
        _entries = Query(filter: #Predicate<PlaylistEntry> {
            $0.dateAdded != nil
            /*
            if let playlistID = $0.playlist  {
                return playlistID.id == playlist.id
            }else{
                return false
            }
            */
        })
    }

    var body: some View {
        Text(playlistname)
        List {
            ForEach(entries.sorted(by: { $0.order < $1.order })) { entry in
                Text(entry.episode?.title ?? "Untitled")
            }
            .onMove { indices, newOffset in
                Task {
                    if let from = indices.first {
                        await viewModel.moveEntry(from: from, to: newOffset)
                    }
                }
            }
        }
        .toolbar {
            EditButton()
        }
    }
}

