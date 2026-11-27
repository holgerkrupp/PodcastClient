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
    @State private var filterState = QueueFilterState.all
    @Environment(DownloadedFilesManager.self) private var fileManager
    /// Cached value snapshot of the matching episodes (#498). Filtering runs
    /// over these values; the projection is rebuilt only when membership,
    /// the file inventory, the playing episode, play state or filters change.
    @State private var projection = QueueProjection(isSmartPlaylist: true, entries: [])
    @State private var episodesByIdentity: [String: Episode] = [:]
    /// Bumped whenever matches are re-read or hydration publishes, so the
    /// same episode IDs with changed episode data are re-snapshotted (#519).
    @State private var projectionGeneration = 0

    let playlist: Playlist

    private var displayedEpisodes: [Episode] {
        matchingEpisodes.filter { $0.url != nil }
    }

    private var filteredEntries: [QueueEpisodeValue] {
        projection.filtered(using: filterState).entries
    }

    private struct ProjectionRebuildKey: Equatable {
        let playlistID: UUID
        let episodeIDs: [PersistentIdentifier]
        let downloadedFiles: Set<URL>
        let currentEpisodeURL: URL?
        let isPlaying: Bool
        let filterState: QueueFilterState
        let generation: Int
    }

    private var projectionRebuildKey: ProjectionRebuildKey {
        ProjectionRebuildKey(
            playlistID: playlist.id,
            episodeIDs: matchingEpisodes.map(\.persistentModelID),
            downloadedFiles: fileManager.downloadedFiles,
            currentEpisodeURL: Player.shared.currentEpisodeURL,
            isPlaying: Player.shared.isPlaying,
            filterState: filterState,
            generation: projectionGeneration
        )
    }

    private func rebuildProjection() {
        let displayed = displayedEpisodes
        projection = QueueProjection(
            playlistID: playlist.id,
            playlistTitle: playlist.displayTitle,
            isSmartPlaylist: true,
            episodes: displayed,
            downloadedFiles: fileManager.downloadedFiles
        )
        episodesByIdentity = Dictionary(
            displayed.map { ($0.stableEpisodeIdentityKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var body: some View {
        Group {
            if displayedEpisodes.isEmpty {
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
                VStack(spacing: 0) {
                    QueueFilterBar(projection: projection, filterState: $filterState)

                    if filteredEntries.isEmpty {
                        ContentUnavailableView {
                            Label("No Matching Episodes", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("Clear filters to see every matching episode.")
                        } actions: {
                            Button("Clear Filters") {
                                filterState.clear()
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

                            ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, value in
                                if let episode = episodesByIdentity[value.stableIdentityKey] {
                            ZStack {
                                EpisodeRowView(
                                    episode: episode,
                                    showsRemoveFromPlaylistAction: false,
                                    usesLivePlaybackProgress: index == 0,
                                    groupPosition: EpisodeRowGroupPosition(index: index, count: filteredEntries.count)
                                )
                                NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                                    EmptyView()
                                }
                                .opacity(0)
                            }
                            .buttonStyle(.plain)
                            .episodeRowSwipeActions(for: episode)
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
        .onReceive(NotificationCenter.default.publisher(for: .splitRuntimeDidHydrate)) { _ in
            projectionGeneration &+= 1
        }
        .onChange(of: playlist.id) { _, _ in
            filterState.clear()
        }
        .onChange(of: projectionRebuildKey, initial: true) { _, _ in
            rebuildProjection()
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
            projectionGeneration &+= 1
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
            projectionGeneration &+= 1
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
