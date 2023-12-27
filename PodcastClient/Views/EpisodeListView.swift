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
    
    @State private var podcastModel: PodcastModel

    @State private var searchText = ""
    

    
    init(modelContext: ModelContext) {
        let podcastModel = PodcastModel(modelContext: modelContext)
        _podcastModel = State(initialValue: podcastModel)
    }
    
    
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
                                
                  
                                PodcastView(for: podcast.persistentModelID)
                                    .modelContext(modelContext)
                    
                            }label:{
                                PodcastMiniView(podcast: podcast)
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
                    Text("\(podcastModel.podcasts.count.description) Podcasts")
                }

    
                Section{
                    AddPodcastView()
                        .modelContext(modelContext)
                        
                }
                
            }
            .searchable(text: $searchText)
        }
    }
    
    

    
    
}


extension PodcastListView {
    @Observable
    class PodcastModel {
        var modelContext: ModelContext
        var podcasts = [Podcast]()
        
        init(modelContext: ModelContext) {
            self.modelContext = modelContext
            fetchData()
        }
        
        
        
        func fetchData() {
            do {
                let descriptor = FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.title)])
                podcasts = try modelContext.fetch(descriptor)
            } catch {
                print("Fetch failed")
            }
        }
    }
}
