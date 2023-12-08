//
//  PodcastList.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import SwiftUI
import SwiftData



struct PodcastListView: View {
    
    @Environment(\.modelContext) var modelContext
    @Query var podcasts: [Podcast]

    @State private var searchText = ""
    
    @State var newFeed:String = "https://hierisauch.net/feed/test/"
    
    
    var body: some View {
        NavigationStack {
            List{
                Section {
                    ForEach(podcasts.filter {
                      
                            searchText != "" ?
                            
                            $0.title.uppercased().contains(searchText.uppercased()) :
                            
                            true
                            
                        }) { podcast in
                            NavigationLink {
                                PodcastView(podcast: podcast)
                                    .modelContext(modelContext)
                                    
                            }label:{
                                Text(podcast.title)
                              //  PodcastMiniView(podcastID: podcast.persistentModelID)
                                //    .modelContext(modelContext)
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
                            
                    
                    
                    
                } header: {
                    Text("Subscribed podcasts")
                } footer: {
                    Text("\(podcasts.count.description) Podcasts")
                }

    
                Section{
                    TextField(text: $newFeed) {
                        Text("paste URL to feed")
                    }
                    Button {
                        
                        if newFeed != "", let feed = URL(string: newFeed.trimmingCharacters(in: .whitespacesAndNewlines)){
                                
                                Task{
                                    if let podcast = await Podcast(with: feed){
                                        print(podcast.feed?.description ?? "feed missing")
                                        
                                        print(podcast.lastModified ?? "last Mod missing")
                                        print(podcast.lastRefresh ?? "last refresh missing")
                                        
                                        modelContext.insert(podcast)
                                        try? modelContext.save()
                                        await podcast.refresh()
                                       
                                        
                                    }

                                }
                            
                        }
                    } label: {
                        Text("Subscribe")
                    }
                    .disabled(URL(string: newFeed) == nil)
                    

                }
                
            }
            .searchable(text: $searchText)
        }
    }
}

#Preview {
    PodcastListView()
}
