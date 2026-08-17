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
            while Task.isCancelled == false {
                await refreshCloudStatus()
                await reconcilePendingPlaylistOnceIfNeeded()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

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

    @MainActor
    private func reconcilePendingPlaylistOnceIfNeeded() async {
        guard PlaylistSilentRecoveryDecision.shouldReconcile(
            initializationError: modelContainerManager.userStateInitializationError,
            localRecordCount: localSplitRecordCount,
            cloudReferenceCount: cloudReferenceCount,
            didRequestAutomaticReconcile: didRequestAutomaticReconcile
        ) else {
            return
        }
        didRequestAutomaticReconcile = true
        await modelContainerManager.prepareSplitStores()
        await StoreSplitWorkCoordinator.shared.runManualReconcile(
            authoritativePlaylists: false
        )
        await refreshCloudStatus()
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
