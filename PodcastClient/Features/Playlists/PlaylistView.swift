//
//  PlaylistView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import SwiftUI
import SwiftData

struct PlaylistView: View {
    @Environment(\.modelContext) var modelContext

    // @State var playlist = PlaylistManager.shared.playnext
    
   
    @Query(filter: #Predicate<PlaylistEntry> { $0.playlist?.title == "de.holgerkrupp.podbay.queue" },
           sort: [SortDescriptor(\PlaylistEntry.order)] ) var playListEntries: [PlaylistEntry]
    
    
    
    var body: some View {
        
        //     Text("\(playlist.ordered.count.description) - Playlist entries")
        let playlist = playListEntries.first?.playlist
        let adjust = SettingsManager.shared.defaultSettings.markAsPlayedAfterSubscribe
      
  
            //    Text("\(episodes.count) Episodes")
            NavigationStack {
                List{
                    
                    ForEach(playListEntries.filter({$0.episode != nil}), id:\.self) { item in
                        let episodeSpeed = item.episode?.podcast?.settings?.playbackSpeed ?? SettingsManager.shared.defaultSettings.playbackSpeed
                        VStack{
                            EpisodeMiniView(episode: item.episode!)
                                .modelContext(modelContext)
                                .swipeActions(edge: .trailing){
                                    Button(role: .destructive) {
                                        withAnimation {
                                            playlist?.items?.removeAll(where: { thisitem in
                                                thisitem == item
                                            })
                                        }

                                    } label: {
                                        Label("Remove from list", systemImage: "xmark.circle.fill")
                                    }
                                }
                                .swipeActions(edge: .leading){
                                    Button(role: .none) {
                                        item.episode?.markAsPlayed()
                                        
                                    } label: {
                                        Label("Mark as played", systemImage: "circle.fill")
                                    }
                                }
                                .tint(.accent)
                            
                            
                        }
                    }
                    .onMove( perform: move )
                }
            }
        
    }
    private func move( from source: IndexSet, to destination: Int)
    {
        // Make an array of items from fetched results
        var revisedItems: [ PlaylistEntry  ] = playListEntries.map{ $0 }
        
        // change the order of the items in the array
        revisedItems.move(fromOffsets: source, toOffset: destination )
        
        // update the userOrder attribute in revisedItems to
        // persist the new order. This is done in reverse order
        // to minimize changes to the indices.
        for reverseIndex in stride( from: revisedItems.count - 1,
                                    through: 0,
                                    by: -1 )
        {
            revisedItems[ reverseIndex ].order =
            Int( reverseIndex )
        }
    }
}






#Preview {
    PlaylistView()
}
