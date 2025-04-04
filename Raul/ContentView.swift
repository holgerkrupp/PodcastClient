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
        case podcasts, add
    }
    
    @State private var selectedTab: Tab = .add
    
    var body: some View {
        TabView(selection: $selectedTab) {
            AddPodcastView()
                .tabItem {
                    Label("Add", systemImage: "plus.circle")
                }
                .tag(Tab.add)
            

                
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

