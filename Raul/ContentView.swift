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
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            PodcastListView(modelContainer: modelContext.container)
                .tabItem {
                    Label("Podcasts", systemImage: "headphones")
                }
                .tag(0)
            
            AddPodcastView()
                .tabItem {
                    Label("Add Podcast", systemImage: "plus.circle")
                }
                .tag(1)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Podcast.self, Episode.self)
}
