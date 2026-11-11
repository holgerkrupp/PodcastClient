import SwiftUI
import SwiftData

private struct SmartPlaylistRefreshKey: Equatable {
    let playlistID: UUID
    let filter: SmartPlaylistFilter?
    let generation: Int
    let scenePhase: ScenePhase
}

/// Smart playlist membership is derived from library episodes and never
/// materialized as PlaylistEntry records.
struct SmartPlaylistPageView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var matchingEpisodes: [Episode] = []
    @State private var isLoadingMatches = true
    @State private var evaluationFailed = false
    @State private var refreshGeneration = 0

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
                    if evaluationFailed {
                        ContentUnavailableView {
                            Label("Couldn't Load Smart Playlist", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        } description: {
                            Text("The filters couldn't be checked. Try again, or open Settings to review them.")
                        } actions: {
                            Button("Try Again") { refreshGeneration &+= 1 }
                        }
                    } else {
                        ContentUnavailableView(
                            "No Matching Episodes",
                            systemImage: playlist.displaySymbolName,
                            description: Text("No library episodes match these filters. Open Settings to edit the filters or wait for matching episodes to appear.")
                        )
                    }
                }
            } else {
                List {
                    if evaluationFailed {
                        Section {
                            Label("Couldn't refresh this smart playlist.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                                .foregroundStyle(.secondary)
                            Button("Try Again") { refreshGeneration &+= 1 }
                        }
                        .listRowSeparator(.hidden)
                    }

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
        .task(id: SmartPlaylistRefreshKey(
            playlistID: playlist.id,
            filter: playlist.smartFilter,
            generation: refreshGeneration,
            scenePhase: scenePhase
        )) {
            guard scenePhase == .active else { return }
            await refreshMatches()
        }
        .onReceive(NotificationCenter.default.publisher(for: .smartPlaylistMembershipCacheDidInvalidate)) { _ in
            refreshGeneration &+= 1
        }
        .navigationTitle(playlist.displayTitle)
    }

    @MainActor
    private func refreshMatches() async {
        if let cachedIDs = SmartPlaylistMembershipCache.episodeIDs(
            for: playlist.id,
            filter: playlist.smartFilter
        ) {
            matchingEpisodes = cachedIDs.compactMap { modelContext.model(for: $0) as? Episode }
            evaluationFailed = false
            isLoadingMatches = false
            return
        }

        isLoadingMatches = matchingEpisodes.isEmpty
        do {
            let episodeIDs = try await SmartPlaylistMembershipCache.matchingEpisodeIDs(
                for: playlist.id,
                filter: playlist.smartFilter,
                using: modelContext.container
            )
            guard Task.isCancelled == false else { return }
            matchingEpisodes = episodeIDs.compactMap { modelContext.model(for: $0) as? Episode }
            evaluationFailed = false
        } catch is CancellationError {
            return
        } catch {
            guard Task.isCancelled == false else { return }
            evaluationFailed = true
        }
        guard Task.isCancelled == false else { return }
        isLoadingMatches = false
    }

}
