//
//  AllEpisodesListView 2.swift
//  Raul
//
//  Created by Holger Krupp on 31.05.25.
//


import SwiftUI
import SwiftData

enum EpisodeListFilterMode {
    case all
    case onlyPlayed
}

struct AllEpisodesListView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var episodes: [Episode] = []
    @State private var searchText: String = ""
    let filterMode: EpisodeListFilterMode
    
    init(filterMode: EpisodeListFilterMode = .all) {
        self.filterMode = filterMode
    }
    
    private var navigationTitleText: String {
        switch filterMode {
        case .all: return "All Episodes"
        case .onlyPlayed: return "Recently Played"
        }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(episodes) { episode in
                        NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                            EpisodeRowView(episode: episode)
                                .id(episode.id)

                        }
                       
                       
                    }
                    
                }
                
            }
            .navigationTitle(navigationTitleText)
            .searchable(text: $searchText)
            .onAppear {
                Task { await fetchEpisodes() }
            }
            .onChange(of: searchText) { oldValue, newValue in
                debounceSearch(newValue)
            }
        }
        .toolbar {

            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { deleteFiles() }
                } label: {
                    Label("Delete Files", systemImage: "trash")
                   
                }
                
            }
        }
        
    }


    
    // MARK: - Fetching Episodes
    
    private func fetchEpisodes(searchText: String = "") async {
        var predicate: Predicate<Episode>? = nil
        
        switch filterMode {
        case .onlyPlayed:
            if searchText.isEmpty {
                predicate = #Predicate<Episode> {
                    $0.metaData?.lastPlayed != nil
                    &&
                    ($0.metaData?.isHistory == true || $0.metaData?.isArchived == true)
                    
                }
            } else {
                predicate = #Predicate<Episode> { 
                    $0.metaData?.lastPlayed != nil
                    
                    &&
                    ($0.metaData?.isHistory == true || $0.metaData?.isArchived == true)
                    
                    &&
                    $0.title.localizedStandardContains(searchText)
                }
            }
            let descriptor = FetchDescriptor<Episode>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.metaData?.lastPlayed, order: .reverse)]
            )
            do {
                episodes = try modelContext.fetch(descriptor)
            } catch {
                print("Fetch error: \(error)")
            }
            
        case .all:
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
    }

    // MARK: - Debounced Search
    
    private func debounceSearch(_ text: String) {
        Debounce.shared.perform {
            Task { await fetchEpisodes(searchText: text) }
        }
    }
    
    
    private func deleteFiles() {
        let urls = episodes.compactMap(\.localFile)
        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                print("Error deleting file: \(error)")
            }
        }
    }
    
    func onlyPlayed() -> some View {
        Self(filterMode: .onlyPlayed)
    }
}

#Preview {
    AllEpisodesListView(filterMode: .all)
        .modelContainer(for: Episode.self, inMemory: true) // Preview-safe
}

