//
//  ListofPodcastsView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 20.02.24.
//

import SwiftUI

struct ListofPodcastsView: View {
    
    @Environment(\.modelContext) var modelContext
    
    @State  var podcasts: [Podcast]
    
    var body: some View {
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
}
