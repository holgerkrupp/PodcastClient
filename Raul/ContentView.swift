//
//  ContentView.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    
    enum Tab: Int {
        case player, podcasts, inbox, downloads
    }
    
    @State private var selectedTab: Tab = .player
   // @ObservedObject private var manager = DownloadManager.shared
    
    @AppStorage("lastPlayedEpisodeID") var lastPlayedEpisode:Int?
    
    var body: some View {
        TabView(selection: $selectedTab) {
            TimelineView()
                .tabItem {
                    Label("Player", systemImage: "play.circle.fill")
                }
                .tag(Tab.player)
            
            InboxView()
                .tabItem {
                    Label("Inbox", systemImage: "tray.fill")
                }
                .tag(Tab.inbox)
            

                
            PodcastListView(modelContainer: modelContext.container)

                .tabItem {
                    Label("Podcasts", systemImage: "headphones")
                }
                .tag(Tab.podcasts)
            


        }
        
  
    }
        
}

#Preview {
    ContentView()
        .modelContainer(for: Podcast.self, inMemory: true, isAutosaveEnabled: true)
}

