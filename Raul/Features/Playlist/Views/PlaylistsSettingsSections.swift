//
//  PlaylistsSettingsSections.swift
//  Raul
//

import SwiftUI
import SwiftData

/// The Playlists category of the main Settings: every manual playlist, with a
/// way to create new ones, delete old ones, and open each one's settings.
///
/// Produces `Section`s so it drops into the settings `Form` like any other
/// category.
struct PlaylistsSettingsSections: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\Playlist.sortIndex, order: .forward), SortDescriptor(\Playlist.title, order: .forward)])
    private var playlists: [Playlist]

    @State private var playlistPendingDeletion: Playlist?

    /// Presented by the stable parent Settings Form, not by a Section inside it.
    let onCreatePlaylist: () -> Void

    private var visiblePlaylists: [Playlist] {
        Playlist.visibleSorted(playlists)
    }

    var body: some View {
        Section {
            ForEach(visiblePlaylists) { playlist in
                NavigationLink {
                    PlaylistSettingsView(playlist: playlist)
                } label: {
                    PlaylistSettingsRow(playlist: playlist)
                }
                .deleteDisabled(playlist.deleteable == false)
                .contextMenu {
                    if playlist.deleteable {
                        Button(role: .destructive) {
                            playlistPendingDeletion = playlist
                        } label: {
                            Label("Delete Playlist…", systemImage: "trash")
                        }
                    }
                }
            }
            .onDelete { offsets in
                // Ask first: a deleted playlist takes its episode order with it,
                // and the removal syncs to every device.
                let candidates = visiblePlaylists
                playlistPendingDeletion = offsets
                    .map { candidates[$0] }
                    .first { $0.deleteable }
            }

            Button {
                onCreatePlaylist()
            } label: {
                Label("New Playlist…", systemImage: "plus")
            }
            .accessibilityHint("Adds a new playlist")
        } header: {
            Text("Playlists")
        } footer: {
            Text("Open a playlist to rename it, change its icon, and set how its episodes are downloaded. Swipe to delete a playlist; the built-in queue cannot be deleted.")
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { playlistPendingDeletion != nil },
                set: { isPresented in
                    if isPresented == false {
                        playlistPendingDeletion = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: playlistPendingDeletion
        ) { playlist in
            Button("Delete Playlist", role: .destructive) {
                PlaylistLibrary.delete(playlist, in: modelContext)
                playlistPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                playlistPendingDeletion = nil
            }
        } message: { _ in
            Text("The episodes stay in your library. Podcasts that added new episodes to this playlist will add them to Up Next instead.")
        }
        .task {
            _ = Playlist.ensureDefaultQueue(in: modelContext)
        }
    }

    private var deletionTitle: LocalizedStringKey {
        guard let playlistPendingDeletion else { return "Delete Playlist?" }
        return "Delete “\(playlistPendingDeletion.displayTitle)”?"
    }
}

private struct PlaylistSettingsRow: View {
    let playlist: Playlist

    private var episodeCount: Int {
        guard playlist.isSmartPlaylist == false else { return 0 }
        return playlist.ordered.reduce(into: 0) { partialResult, entry in
            if entry.episode != nil {
                partialResult += 1
            }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: playlist.displaySymbolName)
                .foregroundStyle(.accent)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.displayTitle)
                    .lineLimit(1)

                Text(playlist.isSmartPlaylist ? "Smart playlist" : "^[\(episodeCount) episode](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if playlist.autoDownloadEnabled {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Downloads episodes automatically")
            }

            if playlist.deleteable == false {
                Text("Default")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
