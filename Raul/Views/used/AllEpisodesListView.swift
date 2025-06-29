//
//  AllEpisodesListView 2.swift
//  Raul
//
//  Created by Holger Krupp on 31.05.25.
//


import SwiftUI
import SwiftData


struct AllEpisodesListView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var episodes: [Episode] = []
    @State private var searchText: String = ""
    
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(episodes) { episode in
                        NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                            EpisodeRowView(episode: episode)
                                .id(episode.id)

                        }
                       
                       
                    }
                    
                }
                
            }
            .navigationTitle("All Episodes")
            .searchable(text: $searchText)
            .onAppear {
                Task { await fetchEpisodes() }
            }
            .onChange(of: searchText) { oldValue, newValue in
                debounceSearch(newValue)
            }
        }
    }


    
    // MARK: - Fetching Episodes
    
    private func fetchEpisodes(searchText: String = "") async {
        var predicate: Predicate<Episode>? = nil
        
        if !searchText.isEmpty {
            predicate = #Predicate<Episode> { $0.title.localizedStandardContains(searchText) }
        }
        
        let descriptor = FetchDescriptor<Episode>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.publishDate, order: .reverse)]
        )
        
        do {
            episodes = try modelContext.fetch(descriptor)
        } catch {
            print("Fetch error: \(error)")
        }
    }

    // MARK: - Debounced Search
    
    private func debounceSearch(_ text: String) {
        Debounce.shared.perform {
            Task { await fetchEpisodes(searchText: text) }
        }
    }
}

#Preview {
    AllEpisodesListView()
        .modelContainer(for: Episode.self, inMemory: true) // Preview-safe
}
