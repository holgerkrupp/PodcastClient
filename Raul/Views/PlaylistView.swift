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
    private var playlistname: String
    @State private var entries:  [PlaylistEntry] = []

    init(playlist: Playlist, container: ModelContainer) {
        _viewModel = StateObject(wrappedValue: PlaylistViewModel(playlist: playlist, container: container))
        self.playlistname = playlist.title
    }

    var body: some View {

        
                ForEach(entries.sorted(by: { $0.order < $1.order }), id: \.id) { entry in
                    if let episode = entry.episode {
                        EpisodeRowView(episode: episode)
                            .id(episode.metaData?.id ?? episode.id)
                            .padding(.horizontal)
                            .background(.ultraThinMaterial)
                        
                    }
                    
                }
                
                .onMove { indices, newOffset in
                    Task {
                        if let from = indices.first {
                            await viewModel.moveEntry(from: from, to: newOffset)
                        }
                    }
                }
                
                
            
            
            
        
        .onChange(of: viewModel.entries) { oldValue, newValue in
        print("loaded \(newValue.count) entries. Previously loaded: (\(oldValue.count))")
        entries = viewModel.entries
    }
        .onAppear {
            Task {
                await viewModel.loadEntries()
                print("Rendering entries manually:")
                for entry in viewModel.entries {
                    print("Entry: \(entry.id), order: \(entry.order), episode title: \(entry.episode?.title ?? "nil")")
                }
               
            }

        }
    }

}


