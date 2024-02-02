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
                    
                    ListofEpisodesView(episodes: episodeModel.episodes.filter {
                        
                        searchText != "" ?
                        
                        $0.title?.uppercased().contains(searchText.uppercased()) ?? false :
                        
                        true
                        
                    })
                    .modelContext(modelContext)
                
                    
                } header: {
                    Text("New Episodes")
                } footer: {
                    Text("")
                }

            }
            .searchable(text: $searchText)
            .refreshable {
                Task{
                    await SubscriptionManager().refreshall()
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
                let descriptor = FetchDescriptor<Episode>(sortBy: [SortDescriptor(\.pubDate, order: .reverse)])
                episodes = try modelContext.fetch(descriptor)
            } catch {
                print("Fetch failed for EpisodeListView")
            }
        }
    }
}
