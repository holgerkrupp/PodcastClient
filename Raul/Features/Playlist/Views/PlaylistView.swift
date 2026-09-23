//
//  PlaylistView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import SwiftUI
import SwiftData
import TipKit

struct PlaylistView: View {
    @Query(sort: [SortDescriptor(\Playlist.sortIndex, order: .forward), SortDescriptor(\Playlist.title, order: .forward)])
    private var playlists: [Playlist]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openPodcastSettings) private var openSettings
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @AppStorage(PlaylistPreferenceKeys.selectedPlaylistID) private var storedPlaylistID: String = ""
    @Binding var requestedEpisodeURL: URL?

    @State private var selectedPlaylistID: String = ""
    @State private var showCreatePlaylistSheet: Bool = false
    @State private var requestedEpisode: Episode?
    @State private var showsRequestedEpisode = false

    private var visiblePlaylists: [Playlist] {
        Playlist.manualVisibleSorted(playlists)
    }

    private var selectedPlaylist: Playlist? {
        let candidateIDs = [selectedPlaylistID, storedPlaylistID]
            .compactMap(UUID.init(uuidString:))

        for candidateID in candidateIDs {
            if let playlist = visiblePlaylists.first(where: { $0.id == candidateID }) {
                return playlist
            }
        }

        // `selectedPlaylistID` is view-local state and starts empty on every
        // launch. Resolve the persisted/default playlist synchronously for the
        // first frame instead of briefly rendering the no-selection branch.
        return visiblePlaylists.first(where: { $0.title == Playlist.defaultQueueTitle })
            ?? visiblePlaylists.first
    }

    /// On a regular-width scene, the playlist picker belongs to the episode
    /// list it changes. Keeping it in the content header also leaves the
    /// trailing system bar free to adapt around the fold. Compact scenes keep
    /// the familiar principal toolbar control.
    private var showsPlaylistPickerInContent: Bool {
        horizontalSizeClass == .regular
    }

    var body: some View {
        VStack {
            if showsPlaylistPickerInContent {
                playlistPicker
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            Group {
                if let selectedPlaylist {
                    ManualPlaylistPageView(playlist: selectedPlaylist)
                        .id(selectedPlaylist.id)
                } else {
                    PlaylistLaunchPlaceholder()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(reduceMotion ? nil : .easeInOut, value: selectedPlaylistID)
        .platformInlineNavigationTitle()
        .toolbar {
            if showsPlaylistPickerInContent == false {
                ToolbarItem(placement: .principal) {
                    playlistPicker
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    openSettings()
                }) {
                    Label("Settings", systemImage: "gear")
                }
                .accessibilityLabel("Settings")
                .accessibilityHint("Open settings")
                .accessibilityInputLabels([Text("Settings"), Text("Open settings")])
            }
        }
        .sheet(isPresented: $showCreatePlaylistSheet) {
            NewPlaylistSheet { draft in
                createPlaylist(from: draft)
            }
        }
        .navigationDestination(isPresented: $showsRequestedEpisode) {
            if let requestedEpisode {
                EpisodeDetailView(episode: requestedEpisode)
            }
        }
        .task {
            ensureDefaultPlaylist()
            syncSelectionWithStorage()
            openRequestedEpisodeIfNeeded()
        }
        .onChange(of: visiblePlaylists.map(\.id)) { _, _ in
            ensureSelectionIsValid()
        }
        .onChange(of: selectedPlaylistID) { _, newValue in
            storedPlaylistID = newValue
        }
        .onChange(of: requestedEpisodeURL) { _, _ in
            openRequestedEpisodeIfNeeded()
        }
    }

    private var playlistPicker: some View {
        PlaylistTitleMenu(
            currentTitle: selectedPlaylist?.displayTitle ?? Playlist.defaultQueueDisplayName,
            currentSymbolName: selectedPlaylist?.displaySymbolName ?? Playlist.defaultQueueSymbolName,
            playlists: visiblePlaylists,
            selectedPlaylistID: selectedPlaylist?.id,
            onSelect: { playlist in
                selectPlaylist(playlist)
            },
            onCreate: {
                showCreatePlaylistSheet = true
            }
        )
    }

    private func ensureDefaultPlaylist() {
        _ = Playlist.ensureDefaultQueue(in: modelContext)
    }

    private func syncSelectionWithStorage() {
        if let selectedID = Playlist.resolvePlaylistID(from: storedPlaylistID),
           visiblePlaylists.contains(where: { $0.id == selectedID }) {
            selectedPlaylistID = selectedID.uuidString
            return
        }

        if let defaultPlaylist = visiblePlaylists.first(where: { $0.title == Playlist.defaultQueueTitle })
            ?? visiblePlaylists.first {
            selectedPlaylistID = defaultPlaylist.id.uuidString
            storedPlaylistID = selectedPlaylistID
        }
    }

    private func ensureSelectionIsValid() {
        if let selectedID = UUID(uuidString: selectedPlaylistID),
           visiblePlaylists.contains(where: { $0.id == selectedID }) {
            return
        }

        if let storedID = UUID(uuidString: storedPlaylistID),
           visiblePlaylists.contains(where: { $0.id == storedID }) {
            selectedPlaylistID = storedID.uuidString
            return
        }

        if let defaultPlaylist = visiblePlaylists.first(where: { $0.title == Playlist.defaultQueueTitle })
            ?? visiblePlaylists.first {
            selectedPlaylistID = defaultPlaylist.id.uuidString
            storedPlaylistID = selectedPlaylistID
        }
    }

    private func selectPlaylist(_ playlist: Playlist) {
        selectedPlaylistID = playlist.id.uuidString
        storedPlaylistID = selectedPlaylistID
    }

    private func createPlaylist(from draft: PlaylistCreationDraft) {
        let playlist = PlaylistLibrary.create(
            name: draft.name,
            symbolName: draft.symbolName,
            in: modelContext
        )
        selectedPlaylistID = playlist.id.uuidString
        storedPlaylistID = selectedPlaylistID
    }

    private func openRequestedEpisodeIfNeeded() {
        guard let requestedEpisodeURL else { return }
        let episodeURL = requestedEpisodeURL
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.url == episodeURL }
        )

        requestedEpisode = try? modelContext.fetch(descriptor).first
        showsRequestedEpisode = requestedEpisode != nil
        self.requestedEpisodeURL = nil
    }
}

private struct PlaylistLaunchPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading playlist…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading playlist")
    }
}

private struct PlaylistTitleMenu: View {
    let currentTitle: String
    let currentSymbolName: String
    let playlists: [Playlist]
    let selectedPlaylistID: UUID?
    let onSelect: (Playlist) -> Void
    let onCreate: () -> Void

    var body: some View {
        Menu {
            ForEach(playlists) { playlist in
                Button {
                    onSelect(playlist)
                } label: {
                    if playlist.id == selectedPlaylistID {
                        HStack {
                            Image(systemName: playlist.displaySymbolName)
                            Text(playlist.displayTitle)
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    } else {
                        Label(playlist.displayTitle, systemImage: playlist.displaySymbolName)
                    }
                }
            }

            Divider()

            Button {
                onCreate()
            } label: {
                Label("New Playlist…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: currentSymbolName)
                    .font(.headline)
                Text(currentTitle)
                    .font(.headline)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current playlist \(currentTitle)")
        .accessibilityHint("Opens playlist picker")
    }
}

private struct ManualPlaylistPageView: View {
    let playlist: Playlist

    @Environment(\.modelContext) private var modelContext
    @Query private var playlistEntries: [PlaylistEntry]
    private let reorderTip = ReorderPlaylistTip()
    init(playlist: Playlist) {
        self.playlist = playlist
        let playlistID = playlist.id
        _playlistEntries = Query(
            filter: #Predicate<PlaylistEntry> { entry in
                entry.playlist?.id == playlistID
            },
            sort: [SortDescriptor(\PlaylistEntry.order, order: .forward)]
        )
    }

    private var episodes: [Episode] {
        playlistEntries.compactMap(\.episode)
    }

    private var hasRenderableEpisodes: Bool {
        episodes.contains { $0.url != nil }
    }

    var body: some View {
        if hasRenderableEpisodes == false {
            PlaylistEmptyView(
                title: playlist.displayTitle,
                isSmartPlaylist: false,
                isDefaultQueue: playlist.title == Playlist.defaultQueueTitle,
                playlistID: playlist.id
            )
        } else {
            List {
                
                TipView(reorderTip, arrowEdge: .none)
                                    .listRowSeparator(.hidden)
                
                ForEach(Array(episodes.enumerated()), id: \.element.persistentModelID) { index, episode in
                    if episode.url != nil {
                        ZStack {
                            EpisodeRowView(
                                episode: episode,
                                showsRemoveFromPlaylistAction: true,
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
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task {
                                    await removeEpisodeFromPlaylist(episode)
                                }
                            } label: {
                                Label("Remove from Playlist", systemImage: "minus.circle")
                            }

                            Button(role: .none) {
                                Task {
                                    await archiveEpisode(episode)
                                }
                            } label: {
                                Label("Mark Archived", systemImage: "archivebox.fill")
                            }
                            .tint(.orange)
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }
                }
                .onMove { indices, newOffset in
                    guard let fromIndex = indices.first else { return }
                    Task {
                        if let actor = try? PlaylistModelActor(modelContainer: modelContext.container, playlistID: playlist.id) {
                            try? await actor.moveEntry(from: fromIndex, to: newOffset)
                        }
                    }
                    ReorderPlaylistTip.hasUserReorderedBefore = true
                    reorderTip.invalidate(reason: .actionPerformed)
                }
                // `initial: true` so the rule sees the current count, not just later changes;
                // otherwise a playlist that never changes size never becomes eligible.
                .onChange(of: episodes.count, initial: true) { _, newCount in
                    ReorderPlaylistTip.playlistItemCount = newCount
                }
            }
            .listStyle(.plain)
        }
    }

    private func archiveEpisode(_ episode: Episode) async {
        let episodeActor = EpisodeActor(modelContainer: modelContext.container)
        await episodeActor.archiveEpisode(episode.url)
    }

    private func removeEpisodeFromPlaylist(_ episode: Episode) async {
        guard let episodeURL = episode.url else { return }
        guard let playlistActor = try? PlaylistModelActor(
            modelContainer: modelContext.container,
            playlistID: playlist.id
        ) else {
            return
        }
        try? await playlistActor.remove(episodeURL: episodeURL)
    }
}
