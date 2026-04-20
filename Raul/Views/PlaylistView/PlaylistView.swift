//
//  PlaylistView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import SwiftUI
import SwiftData

struct PlaylistView: View {
    @Query(sort: [SortDescriptor(\Playlist.sortIndex, order: .forward), SortDescriptor(\Playlist.title, order: .forward)])
    private var playlists: [Playlist]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(PlaylistPreferenceKeys.selectedPlaylistID) private var storedPlaylistID: String = ""

    @State private var selectedPlaylistID: String = ""
    @State private var showSettings: Bool = false
    @State private var showCreatePlaylistSheet: Bool = false

    private var visiblePlaylists: [Playlist] {
        Playlist.manualVisibleSorted(playlists)
    }

    private var selectedPlaylist: Playlist? {
        guard let selectedID = UUID(uuidString: selectedPlaylistID) else {
            return nil
        }
        return visiblePlaylists.first(where: { $0.id == selectedID })
    }

    var body: some View {
        NavigationStack {
            Group {
                if let selectedPlaylist {
                    ManualPlaylistPageView(playlist: selectedPlaylist)
                        .id(selectedPlaylist.id)
                } else {
                    PlaylistEmptyView(title: Playlist.defaultQueueDisplayName, isSmartPlaylist: false)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut, value: selectedPlaylistID)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    PlaylistTitleMenu(
                        currentTitle: selectedPlaylist?.displayTitle ?? Playlist.defaultQueueDisplayName,
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

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        showCreatePlaylistSheet = true
                    }) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create playlist")
                    .accessibilityHint("Adds a new playlist")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        showSettings.toggle()
                    }) {
                        Image(systemName: "gear")
                    }
                    .accessibilityLabel("Queue settings")
                    .accessibilityHint("Open playback and queue settings")
                    .accessibilityInputLabels([Text("Queue settings"), Text("Open settings")])
                }
            }
            .sheet(isPresented: $showSettings) {
                PodcastSettingsView(podcast: nil, modelContainer: modelContext.container, embedInNavigationStack: true)
                    .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: $showCreatePlaylistSheet) {
                NewPlaylistSheet { draft in
                    createPlaylist(from: draft)
                }
            }
        }
        .task {
            ensureDefaultPlaylist()
            syncSelectionWithStorage()
        }
        .onChange(of: visiblePlaylists.map(\.id)) { _, _ in
            ensureSelectionIsValid()
        }
        .onChange(of: selectedPlaylistID) { _, newValue in
            storedPlaylistID = newValue
        }
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
        let allPlaylists = Playlist.manualVisibleSorted(playlists)
        let title = Playlist.normalizedPlaylistName(draft.name.isEmpty ? "Playlist" : draft.name, existing: allPlaylists)

        let playlist = Playlist()
        playlist.title = title
        playlist.deleteable = true
        playlist.hidden = false
        playlist.sortIndex = (allPlaylists.map(\.sortIndex).max() ?? 0) + 1
        playlist.kind = .manual
        playlist.smartFilter = nil

        modelContext.insert(playlist)
        modelContext.saveIfNeeded()

        selectedPlaylistID = playlist.id.uuidString
        storedPlaylistID = selectedPlaylistID
    }
}

private struct PlaylistTitleMenu: View {
    let currentTitle: String
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
                        Label(playlist.displayTitle, systemImage: "checkmark")
                    } else {
                        Text(playlist.displayTitle)
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
        playlistEntries.compactMap { $0.episode }
    }

    var body: some View {
        if episodes.isEmpty {
            PlaylistEmptyView(title: playlist.displayTitle, isSmartPlaylist: false)
        } else {
            List {
                ForEach(episodes, id: \.persistentModelID) { episode in
                    if let episodeURL = episode.url {
                        ZStack {
                            EpisodeRowView(episode: episode)
                            NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                                EmptyView()
                            }
                            .opacity(0)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open episode \(episode.title)")
                        .accessibilityHint("Opens this episode details screen")
                        .swipeActions(edge: .trailing) {
                            Button(role: .none) {
                                Task {
                                    await archiveEpisode(episode)
                                }
                            } label: {
                                Label("Archive Episode", systemImage: "archivebox.fill")
                            }
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .id(episodeURL)
                    }
                }
                .onMove { indices, newOffset in
                    guard let fromIndex = indices.first else { return }
                    Task {
                        if let actor = try? PlaylistModelActor(modelContainer: modelContext.container, playlistID: playlist.id) {
                            try? await actor.moveEntry(from: fromIndex, to: newOffset)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func archiveEpisode(_ episode: Episode) async {
        let episodeActor = EpisodeActor(modelContainer: modelContext.container)
        await episodeActor.archiveEpisode(episode.url)
    }
}

private struct NewPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft = PlaylistCreationDraft()

    let onCreate: (PlaylistCreationDraft) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Playlist") {
                    TextField("Name", text: $draft.name)
                }
            }
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(draft)
                        dismiss()
                    }
                    .disabled(canCreate == false)
                }
            }
        }
    }

    private var canCreate: Bool {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

private struct PlaylistCreationDraft {
    var name: String = ""
}
