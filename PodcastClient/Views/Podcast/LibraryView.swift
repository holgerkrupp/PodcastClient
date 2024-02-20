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
    @Query(sort: [SortDescriptor(\Episode.pubDate, order: .reverse)] ) var episodes: [Episode]

    @State private var listSelection:Selection = .podcast

    
    enum Selection {
        case podcast, episode
    }
    
    var body: some View {

            NavigationStack {
                Picker(selection: $listSelection) {
                    Text("Podcasts").tag(Selection.podcast)
                    Text("Episodes").tag(Selection.episode)

                } label: {
                    Text("Show")
                }
                .pickerStyle(.segmented)

                List{
                    if listSelection == .podcast{
                        ListofPodcastsView(podcasts: podcasts)
                            .modelContext(modelContext)
                    }else{
                        ListofEpisodesView(episodes: episodes)
                            .modelContext(modelContext)
                    }
                }
                    
                
                .refreshable {
                    await SubscriptionManager.shared.refreshall()
                }
            }
    }
}


#Preview {
    LibraryView()
}
