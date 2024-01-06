//
//  PodcastList.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import SwiftUI
import SwiftData



struct EpisodeListView: View {
    
    @Environment(\.modelContext) var modelContext
    @Query var episodes: [Episode]
    
    @State private var episodeModel: EpisodesModel

    @State private var searchText = ""
    

    
    init(modelContext: ModelContext) {
        let episodeModel = EpisodesModel(modelContext: modelContext)
        _episodeModel = State(initialValue: episodeModel)
    }
    
    
    var body: some View {
        NavigationStack {
            List{
                Section {
                    ForEach(episodeModel.episodes.filter {
                      
                            searchText != "" ?
                            
                        $0.title?.uppercased().contains(searchText.uppercased()) ?? false :
                            
                            true
                            
                    }, id:\.self) { episode in
                            NavigationLink {
                                EpisodeView()
                                    .environment(episode)
                                
                            }label:{
                                VStack{
                                    EpisodeMiniView()
                                        .environment(episode)
                                    
                                }
                            }
                        }
                            
                    
                    
                    
                } header: {
                    Text("New Episodes")
                } footer: {
                    Text("")
                }

                
            }
            .searchable(text: $searchText)
            .refreshable {
                Task{
                    await SubscriptionManager.shared.refreshall()
                }
            }
        }
    }
    
    

    
    
}


extension EpisodeListView {
    @Observable
    class EpisodesModel {
        var modelContext: ModelContext
        var episodes = [Episode]()
        
        init(modelContext: ModelContext) {
            self.modelContext = modelContext
            fetchData()
        }
        
        
        
        func fetchData() {
            do {
                print("fetch Episodes for EpisodeListView")
                let descriptor = FetchDescriptor<Episode>(sortBy: [SortDescriptor(\.pubDate, order: .reverse)])
                episodes = try modelContext.fetch(descriptor)
            } catch {
                print("Fetch failed for EpisodeListView")
            }
        }
    }
}
