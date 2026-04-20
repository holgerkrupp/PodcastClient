//
//  EpisodeControlView.swift
//  Raul
//
//  Created by Holger Krupp on 07.04.25.
//


import SwiftUI
import SwiftData

struct EpisodeControlView: View {
    @Bindable var episode: Episode

    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\Playlist.sortIndex, order: .forward), SortDescriptor(\Playlist.title, order: .forward)])
    private var playlists: [Playlist]

    @AppStorage(PlaylistPreferenceKeys.inboxBasePlaylistID) private var preferredPlaylistID: String = ""
    @State private var showFrontPlaylistPicker: Bool = false
    @State private var showBackPlaylistPicker: Bool = false
    @State private var suppressNextFrontTap: Bool = false
    @State private var suppressNextBackTap: Bool = false

    private var manualPlaylists: [Playlist] {
        Playlist.manualVisibleSorted(playlists)
    }

    private var resolvedPlaylistID: UUID? {
        if let explicitID = UUID(uuidString: preferredPlaylistID),
           manualPlaylists.contains(where: { $0.id == explicitID }) {
            return explicitID
        }

        if let defaultPlaylist = manualPlaylists.first(where: { $0.title == Playlist.defaultQueueTitle }) {
            return defaultPlaylist.id
        }

        return manualPlaylists.first?.id
    }

    private var resolvedPlaylistTitle: String {
        guard let resolvedPlaylistID,
              let playlist = manualPlaylists.first(where: { $0.id == resolvedPlaylistID }) else {
            return Playlist.defaultQueueDisplayName
        }

        return playlist.displayTitle
    }

    var body: some View {
        let isInPlaylist = (episode.playlist?.isEmpty ?? true) == false

        HStack {
            Button(action: {
                Task {
                    await Player.shared.playEpisode(episode.url)
                }
            }) {
                Label("Play", systemImage: "play.fill")
                    .symbolRenderingMode(.hierarchical)
                    .scaledToFit()
                    .padding(5)
                    .minimumScaleFactor(0.5)
                    .labelStyle(.iconOnly)
                    .clipShape(Circle())
                    .frame(width: 50)
            }
            .buttonStyle(.glass(.clear))
            .accessibilityLabel("Play episode")
            .accessibilityHint("Starts this episode immediately")

            Spacer()

            GlassEffectContainer(spacing: 20.0) {
                HStack(spacing: 0.0) {
                    Button {
                        if suppressNextFrontTap {
                            suppressNextFrontTap = false
                            return
                        }
                        Task {
                            await addEpisode(to: resolvedPlaylistID, position: .front)
                        }
                    } label: {
                        Label(
                            "Play Next",
                            systemImage: isInPlaylist ? "arrow.up.to.line" : "text.line.first.and.arrowtriangle.forward"
                        )
                        .symbolRenderingMode(.hierarchical)
                        .scaledToFit()
                        .padding(5)
                        .minimumScaleFactor(0.5)
                        .labelStyle(.iconOnly)
                        .frame(width: 50, height: 50)
                    }
                    .buttonStyle(.glass(.clear))
                    .clipShape(Circle())
                    .contentShape(Circle())
                    .accessibilityLabel("Add to playlist")
                    .accessibilityHint("Places this episode at the front of \(resolvedPlaylistTitle)")
                    .onLongPressGesture(minimumDuration: 0.45) {
                        suppressNextFrontTap = true
                        showFrontPlaylistPicker = true
                    }

                    Button {
                        if suppressNextBackTap {
                            suppressNextBackTap = false
                            return
                        }
                        Task {
                            await addEpisode(to: resolvedPlaylistID, position: .end)
                        }
                    } label: {
                        Label(
                            "Play Last",
                            systemImage: isInPlaylist ? "arrow.down.to.line" : "text.line.last.and.arrowtriangle.forward"
                        )
                        .symbolRenderingMode(.hierarchical)
                        .scaledToFit()
                        .padding(5)
                        .minimumScaleFactor(0.5)
                        .labelStyle(.iconOnly)
                        .frame(width: 50, height: 50)
                    }
                    .buttonStyle(.glass(.clear))
                    .clipShape(Circle())
                    .contentShape(Circle())
                    .accessibilityLabel("Add to end of playlist")
                    .accessibilityHint("Places this episode at the end of \(resolvedPlaylistTitle)")
                    .onLongPressGesture(minimumDuration: 0.45) {
                        suppressNextBackTap = true
                        showBackPlaylistPicker = true
                    }
                }
            }

            Spacer()

            Button {
                Task {
                    await EpisodeActor(modelContainer: modelContext.container).archiveEpisode(episode.url)
                }
            } label: {
                Label(
                    episode.metaData?.isArchived ?? false ? "Unarchive" : "Archive",
                    systemImage: episode.metaData?.isArchived ?? false ? "archivebox.fill" : "archivebox"
                )
                .symbolRenderingMode(.hierarchical)
                .scaledToFit()
                .padding(5)
                .minimumScaleFactor(0.5)
                .labelStyle(.iconOnly)
                .clipShape(Circle())
                .frame(width: 50)
            }
            .buttonStyle(.glass(.clear))
            .accessibilityLabel(episode.metaData?.isArchived ?? false ? "Unarchive episode" : "Archive episode")
            .accessibilityHint("Moves this episode in or out of the archive")
        }
        .confirmationDialog("Add To Front", isPresented: $showFrontPlaylistPicker, titleVisibility: .visible) {
            ForEach(manualPlaylists) { playlist in
                Button("Add to front of \(playlist.displayTitle)") {
                    Task {
                        await addEpisode(to: playlist.id, position: .front)
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Add To End", isPresented: $showBackPlaylistPicker, titleVisibility: .visible) {
            ForEach(manualPlaylists) { playlist in
                Button("Add to end of \(playlist.displayTitle)") {
                    Task {
                        await addEpisode(to: playlist.id, position: .end)
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    private func addEpisode(to playlistID: UUID?, position: Playlist.Position) async {
        guard let episodeURL = episode.url else { return }

        let playlistActor: PlaylistModelActor?
        if let playlistID,
           let actor = try? PlaylistModelActor(modelContainer: modelContext.container, playlistID: playlistID) {
            playlistActor = actor
        } else {
            playlistActor = try? PlaylistModelActor(modelContainer: modelContext.container)
        }

        guard let playlistActor else { return }

        if position == .front {
            try? await playlistActor.insert(episodeURL: episodeURL, after: Player.shared.currentEpisodeURL)
        } else {
            try? await playlistActor.add(episodeURL: episodeURL, to: position)
        }
    }
}

#Preview {
    let podcast: Podcast = {
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        podcast.title = "Sample Podcast"
        podcast.author = "Sample Author"
        return podcast
    }()

    let episode: Episode = {
        let episode = Episode(
            title: "Preview Test Episode",
            publishDate: Date(),
            url: URL(string: "https://example.com/ep.mp3")!,
            podcast: podcast,
            duration: 1234,
            author: "Preview Author"
        )
        episode.desc = "A previewable episode for testing controls."
        episode.metaData?.isArchived = false
        return episode
    }()

    EpisodeControlView(episode: episode)
}
