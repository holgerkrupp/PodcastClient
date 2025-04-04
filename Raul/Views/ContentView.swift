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
        case library, inbox
    }
    
    @State private var selectedTab: Tab = .library
    
    var body: some View {
        TabView(selection: $selectedTab) {
            EpisodeListView()
                .tabItem {
                    Label("Inbox", systemImage: "tray.fill")
                }
                .tag(Tab.inbox)
            

                
            PodcastListView(modelContainer: modelContext.container)
                .tabItem {
                    Label("Podcasts", systemImage: "headphones")
                }
                .tag(Tab.library)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Podcast.self, inMemory: true, isAutosaveEnabled: true)
}

