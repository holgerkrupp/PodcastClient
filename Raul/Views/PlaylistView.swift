//
//  PlaylistView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//



import SwiftUI
import SwiftData

struct PlaylistView: View {
    @Query(filter: #Predicate<PlaylistEntry> { $0.playlist?.title == "de.holgerkrupp.podbay.queue" },
           sort: [SortDescriptor(\PlaylistEntry.order)] ) var playListEntries: [PlaylistEntry]
    
    var body: some View {
        
        
        ForEach(playListEntries, id: \.id) { entry in
            if let episode = entry.episode {
                EpisodeRowView(episode: episode)
                    .id(episode.metaData?.id ?? episode.id)
               
            }
            
        }
        .onMove { indices, newOffset in
            Task {
                if let from = indices.first {
                    moveEntry(from: from, to: newOffset)
                }
            }
        }
        
    }
    private func moveEntry(from sourceIndex: Int, to destinationIndex: Int) {


            let sorted = playListEntries.sorted { $0.order < $1.order }

            guard sourceIndex < sorted.count, destinationIndex < sorted.count else { return }

            let movedEntry = sorted[sourceIndex]
            var reordered = sorted
            reordered.remove(at: sourceIndex)
            reordered.insert(movedEntry, at: destinationIndex)

            for (i, entry) in reordered.enumerated() {
                entry.order = i
            }
            
    }
}

/*
struct PlaylistView: View {
    @StateObject private var viewModel: PlaylistViewModel
    private var playlistname: String
    @State private var entries:  [PlaylistEntry] = []

    init(playlistTitle: String = "de.holgerkrupp.podbay.queue", container: ModelContainer) {
        _viewModel = StateObject(wrappedValue: PlaylistViewModel(playlistTitle: playlistTitle, container: container))
        self.playlistname = playlistTitle
    }

    var body: some View {

        
                ForEach(entries, id: \.id) { entry in
                    if let episode = entry.episode {
                        EpisodeRowView(episode: episode)
                            .id(episode.metaData?.id ?? episode.id)
                       

                        
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
               
               
            }

        }
    }

}


*/
