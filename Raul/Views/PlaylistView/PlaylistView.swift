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
    private let fixedPlaylistID: UUID?

    init(fixedPlaylistID: UUID? = nil) {
        self.fixedPlaylistID = fixedPlaylistID
    }

    private var visiblePlaylists: [Playlist] {
        Playlist.manualVisibleSorted(playlists)
    }

    private var selectedPlaylist: Playlist? {
        guard let selectedID = UUID(uuidString: selectedPlaylistID) else {
            return nil
        }
        return visiblePlaylists.first(where: { $0.id == selectedID })
    }

    private var isFixedSelectionMode: Bool {
        fixedPlaylistID != nil
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
            .navigationTitle(isFixedSelectionMode ? (selectedPlaylist?.displayTitle ?? Playlist.defaultQueueDisplayName) : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isFixedSelectionMode == false {
                    ToolbarItem(placement: .topBarLeading) {
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
        if let fixedPlaylistID {
            applyFixedSelection(fixedPlaylistID)
            return
        }

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
        if let fixedPlaylistID {
            applyFixedSelection(fixedPlaylistID)
            return
        }

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
        guard fixedPlaylistID == nil else { return }
        selectedPlaylistID = playlist.id.uuidString
        storedPlaylistID = selectedPlaylistID
    }

    private func applyFixedSelection(_ fixedID: UUID) {
        if visiblePlaylists.contains(where: { $0.id == fixedID }) {
            let value = fixedID.uuidString
            selectedPlaylistID = value
            storedPlaylistID = value
            return
        }

        if let fallbackPlaylist = visiblePlaylists.first(where: { $0.title == Playlist.defaultQueueTitle })
            ?? visiblePlaylists.first {
            selectedPlaylistID = fallbackPlaylist.id.uuidString
            storedPlaylistID = selectedPlaylistID
        }
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
        playlist.symbolName = Playlist.normalizedSymbolName(draft.symbolName, fallback: Playlist.defaultManualSymbolName)
        playlist.smartFilter = nil

        modelContext.insert(playlist)
        modelContext.saveIfNeeded()

        selectedPlaylistID = playlist.id.uuidString
        storedPlaylistID = selectedPlaylistID
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
                                Label("Archive Episode", systemImage: "archivebox.fill")
                            }
                            .tint(.orange)
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

                Section("Icon") {
                    PlaylistSymbolGridPicker(selection: $draft.symbolName)
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
    var symbolName: String = Playlist.defaultManualSymbolName
}

private struct PlaylistSymbolGridPicker: View {
    @Binding var selection: String

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 56, maximum: 70), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(Playlist.symbolOptions) { option in
                Button {
                    selection = option.symbolName
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: option.symbolName)
                            .font(.title3)
                            .frame(maxWidth: .infinity)
                        Text(option.title)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selection == option.symbolName ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(selection == option.symbolName ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Playlist icon \(option.title)")
                .accessibilityAddTraits(selection == option.symbolName ? .isSelected : [])
            }
        }
    }
}
