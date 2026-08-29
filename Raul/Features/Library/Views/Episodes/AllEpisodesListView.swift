//
//  AllEpisodesListView 2.swift
//  Raul
//
//  Created by Holger Krupp on 31.05.25.
//


import SwiftUI
import SwiftData

enum EpisodeListFilterMode: Equatable, Sendable {
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
    @State private var fetchGeneration = 0
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
                ForEach(episodes, id: \.persistentModelID) { episode in
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
            .task {
                await fetchEpisodes()
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
                    Task { await deleteFiles() }
                } label: {
                    Label("Delete Files", systemImage: "trash")
                   
                }
                
            }
        }
        
    }


    
    // MARK: - Fetching Episodes
    
    private func fetchEpisodes(searchText: String = "") async {
        fetchGeneration += 1
        let generation = fetchGeneration
        let recentlyPlayedOnly = filterMode == .onlyPlayed
        let limit = recentlyPlayedOnly
            ? recentlyPlayedDisplayLimit
            : allEpisodesDisplayLimit
        let actor = EpisodeListQueryActor(modelContainer: modelContext.container)

        do {
            let result = try await actor.allEpisodes(
                searchText: searchText,
                limit: limit,
                recentlyPlayedOnly: recentlyPlayedOnly
            )
            guard Task.isCancelled == false, generation == fetchGeneration else {
                return
            }

            let episodesByID: [PersistentIdentifier: Episode] = modelContext.existingModels(
                for: result.episodeIDs
            )
            episodes = result.episodeIDs.compactMap { episodesByID[$0] }
            if recentlyPlayedOnly {
                recentlyPlayedHasMore = result.hasMore
            } else {
                allEpisodesHasMore = result.hasMore
            }
        } catch {
            guard generation == fetchGeneration else { return }
            episodes = []
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
    
    
    private func deleteFiles() async {
        let urls = episodes
            .filter { $0.source != .sideLoaded }
            .compactMap(\.localFile)

        await Task.detached(priority: .utility) {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }.value
    }
    
    func onlyPlayed() -> some View {
        Self(filterMode: .onlyPlayed)
    }
}

#Preview {
    AllEpisodesListView(filterMode: .all)
        .modelContainer(for: Episode.self, inMemory: true) // Preview-safe
}
