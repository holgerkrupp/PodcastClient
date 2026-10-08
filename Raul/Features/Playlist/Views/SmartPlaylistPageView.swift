import SwiftUI
import SwiftData

/// Smart playlist membership is derived from library episodes and never
/// materialized as PlaylistEntry records.
struct SmartPlaylistPageView: View {
    @Query private var allEpisodes: [Episode]
    @State private var matchingEpisodes: [Episode] = []

    let playlist: Playlist

    var body: some View {
        Group {
            if matchingEpisodes.isEmpty {
                ContentUnavailableView(
                    "No Matching Episodes",
                    systemImage: Playlist.smartPlaylistSymbolName,
                    description: Text("Edit this smart playlist's filters or wait for matching episodes to appear.")
                )
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
            refreshMatches()
        }
        .onChange(of: allEpisodes.count) { _, _ in
            refreshMatches()
        }
        .onReceive(NotificationCenter.default.publisher(for: .episodeDownloadFinished)) { _ in
            refreshMatches()
        }
        .onReceive(NotificationCenter.default.publisher(for: .smartPlaylistEpisodeDataDidChange)) { _ in
            refreshMatches()
        }
        .navigationTitle(playlist.displayTitle)
    }

    private func refreshMatches() {
        matchingEpisodes = SmartPlaylistEngine.episodes(from: allEpisodes, for: playlist)
    }
}
