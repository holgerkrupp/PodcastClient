//
//  EpisodeControlView.swift
//  Raul
//
//  Created by Holger Krupp on 07.04.25.
//


import SwiftUI
import SwiftData

struct EpisodeControlPlaylist: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let symbolName: String
    let isDefaultQueue: Bool

    init(playlist: Playlist) {
        id = playlist.id
        title = playlist.displayTitle
        symbolName = playlist.displaySymbolName
        isDefaultQueue = playlist.title == Playlist.defaultQueueTitle
    }
}

private struct EpisodeControlPlaylistsKey: EnvironmentKey {
    static let defaultValue: [EpisodeControlPlaylist] = []
}

extension EnvironmentValues {
    var episodeControlPlaylists: [EpisodeControlPlaylist] {
        get { self[EpisodeControlPlaylistsKey.self] }
        set { self[EpisodeControlPlaylistsKey.self] = newValue }
    }
}

struct EpisodeControlView: View {
    let episode: Episode
    let showsRemoveFromInboxAction: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.episodeControlPlaylists) private var manualPlaylists

    @AppStorage(PlaylistPreferenceKeys.selectedPlaylistID) private var preferredPlaylistID: String = ""
    @State private var isSelectingFrontPlaylist = false
    @State private var isSelectingEndPlaylist = false

    init(episode: Episode, showsRemoveFromInboxAction: Bool = false) {
        self.episode = episode
        self.showsRemoveFromInboxAction = showsRemoveFromInboxAction
    }

    private var resolvedPlaylistID: UUID? {
        if let explicitID = UUID(uuidString: preferredPlaylistID),
           manualPlaylists.contains(where: { $0.id == explicitID }) {
            return explicitID
        }

        if let defaultPlaylist = manualPlaylists.first(where: \.isDefaultQueue) {
            return defaultPlaylist.id
        }

        return manualPlaylists.first?.id
    }

    private var resolvedPlaylistTitle: String {
        guard let resolvedPlaylistID,
              let playlist = manualPlaylists.first(where: { $0.id == resolvedPlaylistID }) else {
            return Playlist.defaultQueueDisplayName
        }

        return playlist.title
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
            if Player.shared.currentEpisodeURL != episode.url {
                Spacer()
                GlassEffectContainer(spacing: 20.0){
                    HStack(spacing: 0.0) {
                        Button {
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
                            .frame(width: 50)
                            .clipShape(Circle())
                        }
                        .buttonStyle(.glass(.clear))
                        .contentShape(Circle())
                        .highPriorityGesture(
                            LongPressGesture(minimumDuration: 0.4)
                                .onEnded { _ in
                                    isSelectingFrontPlaylist = true
                                }
                        )
                        .confirmationDialog("Add to front of playlist", isPresented: $isSelectingFrontPlaylist, titleVisibility: .visible) {
                            ForEach(manualPlaylists) { playlist in
                                Button(playlist.title, systemImage: playlist.symbolName) {
                                    Task {
                                        await addEpisode(to: playlist.id, position: .front)
                                    }
                                }
                            }
                            Button("Cancel", role: .cancel) {}
                        }
                        .accessibilityLabel("Add to playlist")
                        .accessibilityHint("Places this episode at the front of \(resolvedPlaylistTitle)")
                        
                        Button {
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
                            .frame(width: 50)
                        }
                        .buttonStyle(.glass(.clear))
                        .contentShape(Circle())
                        .highPriorityGesture(
                            LongPressGesture(minimumDuration: 0.4)
                                .onEnded { _ in
                                    isSelectingEndPlaylist = true
                                }
                        )
                        .confirmationDialog("Add to end of playlist", isPresented: $isSelectingEndPlaylist, titleVisibility: .visible) {
                            ForEach(manualPlaylists) { playlist in
                                Button(playlist.title, systemImage: playlist.symbolName) {
                                    Task {
                                        await addEpisode(to: playlist.id, position: .end)
                                    }
                                }
                            }
                            Button("Cancel", role: .cancel) {}
                        }
                        .accessibilityLabel("Add to end of playlist")
                        .accessibilityHint("Places this episode at the end of \(resolvedPlaylistTitle)")
                    }
                }
                
                Spacer()
                
                Button {
                    Task {
                        let actor = EpisodeActor(modelContainer: modelContext.container)
                        if showsRemoveFromInboxAction {
                            await actor.removeFromInbox(episode.url)
                        } else if episode.metaData?.isArchived == true {
                            await actor.unarchiveEpisode(episode.url)
                        } else {
                            await actor.archiveEpisode(episode.url)
                        }
                    }
                } label: {
                    Label(
                        showsRemoveFromInboxAction
                            ? "Remove from Inbox"
                            : (episode.metaData?.isArchived ?? false ? "Unarchive" : "Archive"),
                        systemImage: showsRemoveFromInboxAction
                            ? "tray.and.arrow.up.fill"
                            : (episode.metaData?.isArchived ?? false ? "archivebox.fill" : "archivebox")
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
                .accessibilityLabel(
                    showsRemoveFromInboxAction
                        ? "Remove episode from Inbox"
                        : (episode.metaData?.isArchived ?? false ? "Unarchive episode" : "Archive episode")
                )
                .accessibilityHint(
                    showsRemoveFromInboxAction
                        ? "Removes this episode from Inbox without changing archive or playlist membership"
                        : "Changes archive state without changing inbox or playlist membership"
                )
            }
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
