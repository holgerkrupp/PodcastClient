import SwiftUI
import SwiftData

/// Smart playlist membership is derived from library episodes and never
/// materialized as PlaylistEntry records.
struct SmartPlaylistPageView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var matchingEpisodes: [Episode] = []
    @State private var isLoadingMatches = true
    @State private var refreshGeneration = UUID()

    let playlist: Playlist

    var body: some View {
        Group {
            if matchingEpisodes.isEmpty {
                if isLoadingMatches {
                    List {
                        ProgressView("Finding episodes…")
                            .frame(maxWidth: .infinity, minHeight: 100)
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                } else {
                    ContentUnavailableView(
                        "No Matching Episodes",
                        systemImage: playlist.displaySymbolName,
                        description: Text("Edit this smart playlist's filters or wait for matching episodes to appear.")
                    )
                }
            } else {
                List {
                    Section {
                        Text("\(matchingEpisodes.count) matching episodes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .listRowSeparator(.hidden)

                    ForEach(Array(matchingEpisodes.enumerated()), id: \.element.persistentModelID) { index, episode in
                        if episode.url != nil {
                            ZStack {
                                EpisodeRowView(
                                    episode: episode,
                                    showsRemoveFromPlaylistAction: false,
                                    usesLivePlaybackProgress: index == 0
                                )
                                NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                                    EmptyView()
                                }
                                .opacity(0)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open episode \(episode.title)")
                            .accessibilityHint("Opens this episode details screen")
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .task(id: playlist.smartFilter) {
            await refreshMatches()
        }
        .onReceive(NotificationCenter.default.publisher(for: .episodeDownloadFinished)) { _ in
            SmartPlaylistMembershipCache.invalidate()
            Task { await refreshMatches() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .smartPlaylistEpisodeDataDidChange)) { _ in
            SmartPlaylistMembershipCache.invalidate()
            Task { await refreshMatches() }
        }
        .navigationTitle(playlist.displayTitle)
    }

    @MainActor
    private func refreshMatches() async {
        let generation = UUID()
        refreshGeneration = generation

        if let cachedIDs = SmartPlaylistMembershipCache.episodeIDs(
            for: playlist.id,
            filter: playlist.smartFilter
        ) {
            matchingEpisodes = cachedIDs.compactMap { modelContext.model(for: $0) as? Episode }
            isLoadingMatches = false
            return
        }

        isLoadingMatches = matchingEpisodes.isEmpty
        let evaluator = SmartPlaylistEvaluationActor(modelContainer: modelContext.container)
        do {
            let episodeIDs = try await evaluator.matchingEpisodeIDs(for: playlist.id)
            guard Task.isCancelled == false, refreshGeneration == generation else { return }
            SmartPlaylistMembershipCache.store(episodeIDs, for: playlist.id, filter: playlist.smartFilter)
            matchingEpisodes = episodeIDs.compactMap { modelContext.model(for: $0) as? Episode }
        } catch {
            guard refreshGeneration == generation else { return }
            matchingEpisodes = []
        }
        isLoadingMatches = false
    }
}
