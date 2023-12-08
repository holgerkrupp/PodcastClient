//
//  PodcastView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 06.12.23.
//

import SwiftUI
import SwiftData

struct PodcastView: View {
    
    var body: some View {
        List{
            Section {
                Text(podcast.title)
                Text(podcast.desc ?? "")
                    
                    }
            
            
            Section{
                ForEach(podcast.episodes.sorted(by: { $0.pubDate ?? Date() > $1.pubDate ?? Date()})){ episode in
                    NavigationLink {
                        EpisodeView(episode: episode)
                        
                    }label:{
                        Text(episode.title ?? "")
                    }
                }
            }
            
            }
    }
}



struct PodcastMiniView: View {
    
    @Environment(\.modelContext) var modelContext
    var podcastID:PersistentIdentifier
    private var podcast: Podcast?
    
    var body: some View {
        Text(podcast?.title ?? "no title")
    }
    
    init(podcastID: PersistentIdentifier) {
        self.podcastID = podcastID
      //  self.podcast = modelContext.registeredModel(for: podcastID)
    }
}
