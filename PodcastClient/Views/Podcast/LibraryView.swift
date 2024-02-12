//
//  PlaylistView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) var modelContext
    
    
   
    @Query(sort: [SortDescriptor(\Podcast.title, order: .forward)] ) var podcasts: [Podcast]
    

    
    var body: some View {

            NavigationStack {
                
                    List{
                        ForEach(podcasts, id:\.self) { podcast in
                            
                            NavigationLink {
                                
                                PodcastView(podcast: podcast)
                                    .modelContext(modelContext)
                                
                            }label:{
                                PodcastMiniView(podcast: podcast)
                                    .swipeActions(edge: .trailing){
                                        Button(role: .destructive) {
                                            modelContext.delete(podcast)
                                        } label: {
                                            Label("Delete", systemImage: "trash.fill")
                                        }
                                    }
                                    .swipeActions(edge: .leading){
                                        Button {
                                            
                                            Task{
                                                await podcast.refresh()
                                            }
                                        } label: {
                                            Label("refresh", systemImage: "arrow.clockwise")
                                        }
                                    }
                            }
                            
                            
                        }
                    }
                    
                
                .refreshable {
                    await SubscriptionManager().refreshall()
                }
            }
    }
}


#Preview {
    LibraryView()
}
