//
//  PlaylistView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import SwiftUI
import SwiftData

struct InboxView: View {
    @Environment(\.modelContext) var modelContext
    
    
   
    @Query(filter: #Predicate<Episode> {$0.finishedPlaying != true },
           sort: [SortDescriptor(\Episode.pubDate, order: .reverse)] ) var episodes: [Episode]
    

    
    var body: some View {

            NavigationStack {
                List{
                    
                    ForEach(episodes.filter({$0.playlistentries != nil}), id:\.self) { episode in
                            EpisodeMiniView(model: EpisodeListItemModel(episode: episode))
                                .modelContext(modelContext)
                                .swipeActions(edge: .trailing){
                                    Button(role: .destructive) {
                                       

                                    } label: {
                                        Label("Remove from list", systemImage: "xmark.circle.fill")
                                    }
                                }
                                .contextMenu {
                                    Button {
                                        episode.playNow()
                                    } label: {
                                        Label("Play now", systemImage: "play")
                                    }
                                    Button {
                                        PlaylistManager.shared.playnext.add(episode: episode, to: .front)
                                        
                                        
                                    } label: {
                                        Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                    }
                                    Button {
                                        PlaylistManager.shared.playnext.add(episode: episode, to: .end)
                                        
                                    } label: {
                                        Label("Play last", systemImage: "text.line.last.and.arrowtriangle.forward")
                                    }
                                }
                            

                            
                        
                    }
                }
            }
        
    }

}






#Preview {
    PlaylistView()
}
