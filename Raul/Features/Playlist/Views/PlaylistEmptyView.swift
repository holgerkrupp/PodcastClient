//
//  PlaylistEmptyView.swift
//  Raul
//
//  Created by Holger Krupp on 18.05.25.
//

import SwiftUI
import SwiftData

enum PlaylistSilentRecoveryDecision {
    static func shouldShowRecoveringState(
        initializationError: String?,
        localRecordCount: Int,
        cloudReferenceCount: Int?
    ) -> Bool {
        initializationError == nil
            && (localRecordCount > 0 || (cloudReferenceCount ?? 0) > 0)
    }

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
    /// Portable playlist identity (`Playlist.storeSplitSyncID`) used to read
    /// restore readiness; nil for smart playlists, which evaluate rules locally.
    var playlistSyncID: String?

    @Query private var allPodcasts: [Podcast]
    @StateObject private var modelContainerManager = ModelContainerManager.shared
    @State private var restoreStatus = PlaylistRestoreStatusModel()
    @State private var didRequestAutomaticReconcile = false

    private var syncID: String? {
        guard isSmartPlaylist == false else { return nil }
        if let playlistSyncID { return playlistSyncID }
        if isDefaultQueue { return Playlist.defaultQueueSyncID }
        return playlistID?.uuidString
    }

    private var showsRestoreStatus: Bool {
        syncID != nil
            && modelContainerManager.userStateInitializationError == nil
            && restoreStatus.readiness.isVisible
    }

    var body: some View {
        Group {
            if showsRestoreStatus {
                PlaylistRestoreStatusView(
                    readiness: restoreStatus.readiness,
                    loginFeed: restoreStatus.facts.loginFeed,
                    isDefaultQueue: isDefaultQueue,
                    isRetrying: restoreStatus.isRetrying,
                    style: .page,
                    onRetry: retry
                )
                .accessibilityElement(children: .contain)
            } else if allPodcasts.isEmpty {
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
        .modifier(OptionalRestoreRefresh(
            model: restoreStatus,
            syncID: syncID,
            isDefaultQueue: isDefaultQueue
        ))
        .task {
            // A bounded probe, not a poll. The split stores can still be
            // preparing when this view first appears, so readiness is re-read
            // a few times; once the silent recovery has been requested (or the
            // window lapses) hydration progress drives further updates.
            guard let syncID else { return }
            for attempt in 0..<Self.recoveryProbeLimit {
                await restoreStatus.refresh(
                    playlistSyncID: syncID,
                    isDefaultQueue: isDefaultQueue,
                    resolvedCount: 0
                )
                if await reconcilePendingPlaylistOnceIfNeeded(syncID: syncID) { return }
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

    private func retry() {
        guard let syncID else { return }
        Task {
            await restoreStatus.retry(
                playlistSyncID: syncID,
                isDefaultQueue: isDefaultQueue,
                resolvedCount: 0
            )
        }
    }

    /// Returns `true` once the silent recovery has been requested, so the
    /// caller can stop probing.
    @MainActor
    @discardableResult
    private func reconcilePendingPlaylistOnceIfNeeded(syncID: String) async -> Bool {
        guard PlaylistSilentRecoveryDecision.shouldReconcile(
            initializationError: modelContainerManager.userStateInitializationError,
            localRecordCount: restoreStatus.facts.referenceCount,
            cloudReferenceCount: StoreSplitPlaylistPresenceStore
                .cloudReferenceCount(forDefaultQueue: isDefaultQueue),
            didRequestAutomaticReconcile: didRequestAutomaticReconcile
        ) else {
            return didRequestAutomaticReconcile
        }
        didRequestAutomaticReconcile = true
        await modelContainerManager.prepareSplitStores()
        await StoreSplitWorkCoordinator.shared.runManualReconcile(
            authoritativePlaylists: false
        )
        await restoreStatus.refresh(
            playlistSyncID: syncID,
            isDefaultQueue: isDefaultQueue,
            resolvedCount: 0
        )
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

private struct OptionalRestoreRefresh: ViewModifier {
    let model: PlaylistRestoreStatusModel
    let syncID: String?
    let isDefaultQueue: Bool

    func body(content: Content) -> some View {
        if let syncID {
            content.refreshesPlaylistRestoreStatus(
                model,
                playlistSyncID: syncID,
                isDefaultQueue: isDefaultQueue,
                resolvedCount: 0
            )
        } else {
            content
        }
    }
}

#Preview {
    PlaylistEmptyView()
}
