//
//  EpisodeControlView.swift
//  Raul
//
//  Created by Holger Krupp on 07.04.25.
//


import SwiftUI
import SwiftData
import TipKit

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
    let showsRemoveFromPlaylistAction: Bool
    /// Only one screen should anchor the playlist picker tip; list rows would
    /// otherwise compete to present the same popover.
    let showsPlaylistPickerTip: Bool
    /// The full episode detail uses a prominent playback action and a single
    /// native queue menu. Library rows keep their existing compact controls.
    let usesDetailLayout: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.episodeControlPlaylists) private var manualPlaylists
    @Bindable private var player = Player.shared

    @AppStorage(PlaylistPreferenceKeys.selectedPlaylistID) private var preferredPlaylistID: String = ""
    @State private var isSelectingFrontPlaylist = false
    @State private var isSelectingEndPlaylist = false
    private let choosePlaylistTip = ChoosePlaylistTip()

    init(
        episode: Episode,
        showsRemoveFromInboxAction: Bool = false,
        showsRemoveFromPlaylistAction: Bool = false,
        showsPlaylistPickerTip: Bool = false,
        usesDetailLayout: Bool = false
    ) {
        self.episode = episode
        self.showsRemoveFromInboxAction = showsRemoveFromInboxAction
        self.showsRemoveFromPlaylistAction = showsRemoveFromPlaylistAction
        self.showsPlaylistPickerTip = showsPlaylistPickerTip
        self.usesDetailLayout = usesDetailLayout
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

    @ViewBuilder
    var body: some View {
        let isInPlaylist = (episode.playlist?.isEmpty ?? true) == false

        if usesDetailLayout {
            detailLayout(isInPlaylist: isInPlaylist)
        } else {
        HStack {
            Button(action: {
                Task {
                    await Player.shared.playEpisode(episode.url)
                }
            }) {
                Label("Play", systemImage: "play.fill")
                    .symbolRenderingMode(.hierarchical)
                    .scaledToFit()
                    .esaForeground(.control)
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
                            .esaForeground(.control)
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
                                    choosePlaylistTip.invalidate(reason: .actionPerformed)
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
                        .help("Add to the front of \(resolvedPlaylistTitle)")
                        .popoverTip(showsPlaylistPickerTip ? choosePlaylistTip : nil)
                        .task(id: manualPlaylists.count) {
                            guard showsPlaylistPickerTip else { return }
                            ChoosePlaylistTip.manualPlaylistCount = manualPlaylists.count
                        }

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
                            .esaForeground(.control)
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
                                    choosePlaylistTip.invalidate(reason: .actionPerformed)
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
                        .help("Add to the end of \(resolvedPlaylistTitle)")
                    }
                }
                
                Spacer()
                
                Button {
                    Task {
                        let actor = EpisodeActor(modelContainer: modelContext.container)
                        if showsRemoveFromInboxAction {
                            await actor.removeFromInbox(episode.url)
                        } else if showsRemoveFromPlaylistAction {
                            if let episodeURL = episode.url {
                                await actor.removeFromPlaylist(episodeURL)
                            }
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
                            : (showsRemoveFromPlaylistAction
                                ? "Remove from Playlist"
                                : (episode.metaData?.isArchived ?? false ? "Unarchive" : "Archive")),
                        systemImage: showsRemoveFromInboxAction
                            ? "tray.and.arrow.up.fill"
                            : (showsRemoveFromPlaylistAction
                                ? "minus.circle"
                                : (episode.metaData?.isArchived ?? false ? "archivebox.fill" : "archivebox"))
                    )
                    .symbolRenderingMode(.hierarchical)
                    .scaledToFit()
                    .esaForeground(.control)
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
                        : (showsRemoveFromPlaylistAction
                            ? "Remove episode from playlist"
                            : (episode.metaData?.isArchived ?? false ? "Unarchive episode" : "Archive episode"))
                )
                .accessibilityHint(
                    showsRemoveFromInboxAction
                        ? "Removes this episode from Inbox without changing archive or playlist membership"
                        : (showsRemoveFromPlaylistAction
                            ? "Removes this episode from the playlist without changing archive or inbox membership"
                            : "Changes archive state without changing inbox or playlist membership")
                )
            }
        }
        }
    }

    private func detailLayout(isInPlaylist: Bool) -> some View {
        HStack(spacing: 10) {
            Button(action: playOrToggleEpisode) {
                Label(playbackActionTitle, systemImage: playbackActionSymbol)
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(playbackActionTitle)
            .accessibilityHint(playbackActionHint)

            Menu {
                Button("Add to Up Next", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    Task { await addEpisode(to: defaultQueueID, position: .end) }
                }
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    Task { await addEpisode(to: resolvedPlaylistID, position: .front) }
                }
                Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    Task { await addEpisode(to: resolvedPlaylistID, position: .end) }
                }

                if manualPlaylists.isEmpty == false {
                    Divider()
                    Menu("Add to Playlist") {
                        ForEach(manualPlaylists) { playlist in
                            Menu(playlist.title, systemImage: playlist.symbolName) {
                                Button("Play Next") {
                                    Task { await addEpisode(to: playlist.id, position: .front) }
                                }
                                Button("Play Last") {
                                    Task { await addEpisode(to: playlist.id, position: .end) }
                                }
                            }
                        }
                    }
                }
            } label: {
                Label("Queue", systemImage: isInPlaylist ? "checkmark.circle" : "text.badge.plus")
                    .labelStyle(.titleAndIcon)
                    .frame(minHeight: 50)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Choose where this episode goes in Up Next or a playlist")
            .popoverTip(showsPlaylistPickerTip ? choosePlaylistTip : nil)
            .task(id: manualPlaylists.count) {
                guard showsPlaylistPickerTip else { return }
                ChoosePlaylistTip.manualPlaylistCount = manualPlaylists.count
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var defaultQueueID: UUID? {
        manualPlaylists.first(where: \.isDefaultQueue)?.id
    }

    private var playbackActionTitle: String {
        guard isCurrentEpisode else {
            return episode.hasPlaybackHistory ? "Resume" : "Play"
        }
        return player.isPlaying ? "Pause" : "Resume"
    }

    private var playbackActionSymbol: String {
        playbackActionTitle == "Pause" ? "pause.fill" : "play.fill"
    }

    private var playbackActionHint: String {
        switch playbackActionTitle {
        case "Pause": "Pauses this episode"
        case "Resume": "Continues this episode from its saved position"
        default: "Starts this episode immediately"
        }
    }

    private var isCurrentEpisode: Bool {
        guard let episodeURL = episode.url else { return false }
        return player.currentEpisodeURL == episodeURL
    }

    private func playOrToggleEpisode() {
        if isCurrentEpisode {
            if player.isPlaying {
                player.pause()
            } else {
                player.play()
            }
        } else {
            Task { await player.playEpisode(episode.url) }
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
