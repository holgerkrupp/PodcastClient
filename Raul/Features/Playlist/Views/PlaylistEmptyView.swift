//
//  PlaylistEmptyView.swift
//  Raul
//
//  Created by Holger Krupp on 18.05.25.
//

import SwiftUI
import SwiftData

enum PlaylistSilentRecoveryDecision {
    static func shouldReconcile(
        initializationError: String?,
        localRecordCount: Int,
        cloudReferenceCount: Int?,
        didRequestAutomaticReconcile: Bool
    ) -> Bool {
        initializationError == nil
            && didRequestAutomaticReconcile == false
            && (localRecordCount > 0 || (cloudReferenceCount ?? 0) > 0)
    }
}

struct PlaylistEmptyView: View {
    var title: String? = nil
    var isSmartPlaylist: Bool = false
    var isDefaultQueue: Bool = false
    var playlistID: UUID?
    
    @Query private var allPodcasts: [Podcast]
    @StateObject private var modelContainerManager = ModelContainerManager.shared
    @State private var cloudReferenceCount: Int?
    @State private var localSplitRecordCount = 0
    @State private var didRequestAutomaticReconcile = false
    
    var body: some View {
        Group {
            if allPodcasts.isEmpty {
                PodcastsEmptyView()
            } else {
                VStack {
                    Text(emptyTitle)
                        .font(.headline)
                    Divider()
                    Text(emptyBody)
                }
                .padding()
            }
        }
        .task {
            // A bounded probe, not a poll. The split stores can still be
            // preparing when this view first appears, so the counts are
            // re-read a few times; once the silent recovery has been requested
            // (or the window lapses) there is nothing left to watch. The old
            // `while` loop kept re-running these main-actor SwiftData counts
            // for as long as the playlist tab existed.
            for attempt in 0..<Self.recoveryProbeLimit {
                await refreshCloudStatus()
                if await reconcilePendingPlaylistOnceIfNeeded() { return }
                guard attempt + 1 < Self.recoveryProbeLimit else { return }
                do {
                    try await Task.sleep(for: Self.recoveryProbeInterval)
                } catch {
                    return
                }
            }
        }
    }

    /// Roughly 30s of probing, which comfortably covers store preparation on a
    /// cold launch.
    private static let recoveryProbeLimit = 15
    private static let recoveryProbeInterval: Duration = .seconds(2)

    @MainActor
    private func refreshCloudStatus() async {
        cloudReferenceCount = StoreSplitPlaylistPresenceStore
            .cloudReferenceCount(forDefaultQueue: isDefaultQueue)
        guard let container = modelContainerManager.preparedUserStateContainer else {
            localSplitRecordCount = 0
            return
        }
        if isDefaultQueue {
            let counts = await StoreSplitPlaylistPresenceStore.localRecordCounts(
                modelContainer: container
            )
            localSplitRecordCount = counts.queueEntries
        } else if let playlistID {
            localSplitRecordCount = await StoreSplitPlaylistPresenceStore
                .localPlaylistEntryCount(
                    playlistID: playlistID,
                    modelContainer: container
                )
        } else {
            localSplitRecordCount = 0
        }
    }

    /// Returns `true` once the silent recovery has been requested, so the
    /// caller can stop probing.
    @MainActor
    @discardableResult
    private func reconcilePendingPlaylistOnceIfNeeded() async -> Bool {
        guard PlaylistSilentRecoveryDecision.shouldReconcile(
            initializationError: modelContainerManager.userStateInitializationError,
            localRecordCount: localSplitRecordCount,
            cloudReferenceCount: cloudReferenceCount,
            didRequestAutomaticReconcile: didRequestAutomaticReconcile
        ) else {
            return didRequestAutomaticReconcile
        }
        didRequestAutomaticReconcile = true
        await modelContainerManager.prepareSplitStores()
        await StoreSplitWorkCoordinator.shared.runManualReconcile(
            authoritativePlaylists: false
        )
        await refreshCloudStatus()
        return true
    }

    private var emptyTitle: String {
        if let title, title.isEmpty == false {
            return "\(title) is empty"
        }
        return "Your Playlist is empty"
    }

    private var emptyBody: String {
        if isSmartPlaylist {
            return "Adjust your smart playlist filters or keep listening. Matching episodes will appear automatically."
        }

        return "Add episodes from your subscribed podcasts to listen to. The episodes will be played in the order they were added to your playlist. You can rearrange them by dragging them in the list."
    }
}

#Preview {
    PlaylistEmptyView()
}
