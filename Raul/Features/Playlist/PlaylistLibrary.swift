//
//  PlaylistLibrary.swift
//  Raul
//

import Foundation
import SwiftData

/// Creating and deleting manual playlists, shared by every screen that offers it
/// so the sync publish, tombstone and selection repair cannot drift apart.
@MainActor
enum PlaylistLibrary {
    @discardableResult
    static func perform(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return true
        } catch {
            ModelContainerManager.shared.playlistSaveFailed = true
            CrashBreadcrumbs.shared.record("playlist_mutation_failed")
            return false
        }
    }

    @discardableResult
    static func create(
        name: String,
        symbolName: String,
        kind: Playlist.Kind = .manual,
        smartFilter: SmartPlaylistFilter? = nil,
        in context: ModelContext,
        userStateContainer: ModelContainer? = nil
    ) throws -> Playlist {
        let existing = Playlist.visibleSorted(
            (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        )

        let playlist = Playlist()
        playlist.title = Playlist.normalizedPlaylistName(name, existing: existing)
        playlist.deleteable = true
        playlist.hidden = false
        playlist.sortIndex = (existing.map(\.sortIndex).max() ?? 0) + 1
        playlist.kind = kind
        playlist.symbolName = Playlist.normalizedSymbolName(
            symbolName,
            fallback: Playlist.defaultManualSymbolName
        )
        playlist.smartFilter = kind == .smart ? (smartFilter ?? SmartPlaylistFilter()) : nil

        context.insert(playlist)
        do {
            try context.commitChangesIfNeeded()
            try StoreSplitPlaylistSyncCoordinator.publish(playlist, userStateContainer: userStateContainer)
        } catch {
            context.delete(playlist)
            try? context.commitChangesIfNeeded()
            throw error
        }
        return playlist
    }

    /// Deletes a playlist and its entries. The episodes themselves are untouched.
    ///
    /// Podcasts that queued into it fall back to the built-in queue on their own
    /// (see `PodcastSettingsModelActor.podcastsRouted(toPlaylistID:)`), so only
    /// the stored playlist selection needs repairing here.
    static func delete(
        _ playlist: Playlist,
        in context: ModelContext,
        defaults: UserDefaults = .standard,
        userStateContainer: ModelContainer? = nil
    ) throws {
        guard playlist.deleteable,
              playlist.title != Playlist.defaultQueueTitle else { return }

        // Persist the explicit deletion before changing the runtime projection.
        try StoreSplitPlaylistSyncCoordinator.tombstone(playlistID: playlist.storeSplitSyncID, in: context, userStateContainer: userStateContainer)
        let defaultQueue = Playlist.ensureDefaultQueue(in: context)
        if defaults.string(forKey: PlaylistPreferenceKeys.selectedPlaylistID) == playlist.id.uuidString {
            defaults.set(defaultQueue.id.uuidString, forKey: PlaylistPreferenceKeys.selectedPlaylistID)
        }

        for entry in playlist.items ?? [] {
            context.delete(entry)
        }
        context.delete(playlist)
        try context.commitChangesIfNeeded()
    }
}
