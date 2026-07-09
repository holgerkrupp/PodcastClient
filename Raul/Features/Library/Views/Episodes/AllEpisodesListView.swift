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
    private static let allEpisodesPageSize = 100
    private static let recentlyPlayedPageSize = 50

    @Environment(\.modelContext) private var modelContext
    @State private var episodes: [Episode] = []
    @State private var searchText: String = ""
    @State private var allEpisodesDisplayLimit = Self.allEpisodesPageSize
    @State private var allEpisodesHasMore = false
    @State private var recentlyPlayedDisplayLimit = Self.recentlyPlayedPageSize
    @State private var recentlyPlayedHasMore = false
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
            List {
                ForEach(episodes) { episode in
                    ZStack{
                        EpisodeRowView(episode: episode)

                        NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                            EmptyView()
                        }.opacity(0)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .onAppear {
                        loadMoreIfNeeded(currentEpisode: episode)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(navigationTitleText)
            .searchable(text: $searchText)
            .onAppear {
                Task { await fetchEpisodes() }
            }
            .onChange(of: searchText) { oldValue, newValue in
                allEpisodesDisplayLimit = Self.allEpisodesPageSize
                recentlyPlayedDisplayLimit = Self.recentlyPlayedPageSize
                debounceSearch(newValue)
            }
        }
        .toolbar {

            ToolbarItem(placement: .primaryAction) {
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
            let metadataPredicate: Predicate<EpisodeMetaData>
            if searchText.isEmpty {
                metadataPredicate = #Predicate<EpisodeMetaData> {
                    $0.lastPlayed != nil
                }
            } else {
                metadataPredicate = #Predicate<EpisodeMetaData> {
                    $0.lastPlayed != nil
                    && $0.episode?.title.localizedStandardContains(searchText) == true
                }
            }
            var descriptor = FetchDescriptor<EpisodeMetaData>(
                predicate: metadataPredicate,
                sortBy: [SortDescriptor(\EpisodeMetaData.lastPlayed, order: .reverse)]
            )
            descriptor.fetchLimit = recentlyPlayedDisplayLimit

            do {
                let totalCount = try modelContext.fetchCount(FetchDescriptor<EpisodeMetaData>(predicate: metadataPredicate))
                recentlyPlayedHasMore = totalCount > recentlyPlayedDisplayLimit
                episodes = try modelContext.fetch(descriptor).compactMap(\.episode)
            } catch {
                // print("Fetch error: \(error)")
            }
            
        case .all:
            if !searchText.isEmpty {
                predicate = #Predicate<Episode> { $0.title.localizedStandardContains(searchText) }
            }
            var descriptor = FetchDescriptor<Episode>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.publishDate, order: .reverse)]
            )
            descriptor.fetchLimit = allEpisodesDisplayLimit
            do {
                let totalCount = try modelContext.fetchCount(FetchDescriptor<Episode>(predicate: predicate))
                allEpisodesHasMore = totalCount > allEpisodesDisplayLimit
                episodes = try modelContext.fetch(descriptor)
            } catch {
                // print("Fetch error: \(error)")
            }
        }
    }

    // MARK: - Debounced Search
    
    private func debounceSearch(_ text: String) {
        Debounce.shared.perform(key: "AllEpisodesListView.search") {
            Task { await fetchEpisodes(searchText: text) }
        }
    }

    private func loadMoreIfNeeded(currentEpisode: Episode) {
        guard episodes.last?.persistentModelID == currentEpisode.persistentModelID else { return }

        switch filterMode {
        case .all:
            guard allEpisodesHasMore else { return }
            allEpisodesDisplayLimit += Self.allEpisodesPageSize
        case .onlyPlayed:
            guard recentlyPlayedHasMore else { return }
            recentlyPlayedDisplayLimit += Self.recentlyPlayedPageSize
        }

        Task { await fetchEpisodes(searchText: searchText) }
    }
    
    
    private func deleteFiles() {
        let urls = episodes
            .filter { $0.source != .sideLoaded }
            .compactMap(\.localFile)
        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                // print("Error deleting file: \(error)")
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
