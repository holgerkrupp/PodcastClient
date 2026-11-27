import SwiftUI
import SwiftData

/// Loads the restore readiness of one Queue or manual playlist (#443, #483).
/// Reads run off the main actor and are re-run only when hydration publishes,
/// finishes or connectivity changes; nothing here polls.
@MainActor
@Observable
final class PlaylistRestoreStatusModel {
    private(set) var readiness: PlaylistRestoreReadiness = .empty
    private(set) var facts = PlaylistRestoreFacts()
    private(set) var isRetrying = false
    private(set) var hasLoaded = false

    func refresh(playlistSyncID: String, isDefaultQueue: Bool, resolvedCount: Int) async {
        let manager = ModelContainerManager.shared
        let monitor = LibraryRestoreMonitor.shared
        var facts = PlaylistRestoreFacts()
        if let library = manager.preparedContainer {
            let userState = manager.preparedUserStateContainer
            facts = await Task.detached(priority: .utility) {
                PlaylistRestoreFacts.read(
                    playlistSyncID: playlistSyncID,
                    includesLegacyQueueEntries: isDefaultQueue,
                    library: library,
                    userState: userState
                )
            }.value
        } else {
            facts.readFailed = true
        }
        guard Task.isCancelled == false else { return }
        self.facts = facts
        // The facts count the local playlist themselves; the caller's
        // projection count only covers a not-yet-prepared library.
        let resolved = facts.readFailed ? resolvedCount : facts.resolvedCount
        readiness = .derive(.init(
            referenceCount: facts.readFailed ? resolved : facts.referenceCount,
            resolvedCount: resolved,
            cloudReferenceCount: StoreSplitPlaylistPresenceStore
                .cloudReferenceCount(forDefaultQueue: isDefaultQueue),
            awaitingInitialImport: manager.requiresInitialCloudImport,
            pendingFeedCount: facts.pendingFeedCount,
            waitingFeedCount: facts.waitingFeedCount,
            loginFeedCount: facts.loginFeedCount,
            failedFeedCount: facts.failedFeedCount,
            inFlightFeedCount: facts.unresolvedFeedKeys.intersection(monitor.inFlightFeedKeys).count,
            isHydrating: monitor.isHydrating || isRetrying,
            isOffline: monitor.isOffline,
            readFailed: facts.readFailed && resolved == 0
        ))
        hasLoaded = true
    }

    /// Re-runs hydration for this playlist's pending feeds, then re-projects.
    func retry(playlistSyncID: String, isDefaultQueue: Bool, resolvedCount: Int) async {
        guard isRetrying == false else { return }
        isRetrying = true
        await ModelContainerManager.shared.retryPlaylistRestore(feeds: facts.retryFeeds)
        isRetrying = false
        await refresh(playlistSyncID: playlistSyncID, isDefaultQueue: isDefaultQueue, resolvedCount: resolvedCount)
    }
}

/// Honest, non-blocking restore status for a Queue or playlist: counts,
/// what it is waiting for, and a targeted Retry or sign-in link. Never an
/// alert, sheet or overlay.
struct PlaylistRestoreStatusView: View {
    enum Style {
        /// Fills the empty playlist area.
        case page
        /// One row above already restored entries.
        case row
    }

    let readiness: PlaylistRestoreReadiness
    let loginFeed: URL?
    let isDefaultQueue: Bool
    let isRetrying: Bool
    let style: Style
    let onRetry: () -> Void

    var body: some View {
        switch style {
        case .page:
            VStack(spacing: 12) {
                icon
                    .font(.title2)
                    .foregroundStyle(.secondary)
                title
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let progress {
                    ProgressView(value: Double(progress.resolved), total: Double(max(progress.total, 1)))
                        .frame(maxWidth: 240)
                }
                message
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                actions
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .row:
            HStack(alignment: .top, spacing: 12) {
                icon
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    title
                        .font(.subheadline.weight(.semibold))
                    message
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let progress {
                        ProgressView(value: Double(progress.resolved), total: Double(max(progress.total, 1)))
                    }
                    actions
                        .font(.caption)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal)
        }
    }

    private var progress: (resolved: Int, total: Int)? {
        switch readiness {
        case .restoring(let resolved, let total), .partial(let resolved, let total, _):
            (resolved, total)
        case .empty, .unknown, .waitingForICloud, .complete:
            nil
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch readiness {
        case .waitingForICloud:
            Image(systemName: "icloud.and.arrow.down")
        case .restoring:
            Image(systemName: "arrow.down.circle")
        case .partial(_, _, .offline):
            Image(systemName: "wifi.slash")
        case .partial(_, _, .needsLogin):
            Image(systemName: "lock")
        case .partial(_, _, .waiting):
            Image(systemName: "clock")
        case .partial(_, _, .unavailable):
            Image(systemName: "exclamationmark.circle")
        case .empty, .unknown, .complete:
            EmptyView()
        }
    }

    @ViewBuilder
    private var title: some View {
        switch readiness {
        case .waitingForICloud:
            Text("Waiting for iCloud")
        case .restoring:
            if isDefaultQueue {
                Text("Restoring Up Next")
            } else {
                Text("Restoring Playlist")
            }
        case .partial(_, _, .offline):
            Text("Offline")
        case .partial(_, _, .needsLogin):
            Text("Sign-In Needed")
        case .partial(_, _, .waiting):
            Text("Waiting to Load Episodes")
        case .partial(_, _, .unavailable):
            Text("Some Episodes Aren’t Available Yet")
        case .empty, .unknown, .complete:
            EmptyView()
        }
    }

    @ViewBuilder
    private var message: some View {
        switch readiness {
        case .waitingForICloud:
            Text("Your saved episodes appear here when iCloud delivers them to this device.")
        case .restoring(let resolved, let total):
            Text("\(resolved) of \(total) episodes ready. Podcast feeds are loading on this device; episodes appear as each feed finishes.")
        case .partial(let resolved, let total, .offline):
            Text("\(resolved) of \(total) episodes ready. Restoring continues when this device is back online.")
        case .partial(let resolved, let total, .needsLogin):
            Text("\(resolved) of \(total) episodes ready. A private podcast needs you to sign in on this device.")
        case .partial(let resolved, let total, .waiting):
            Text("\(resolved) of \(total) episodes ready. Their podcast feeds load again automatically, or tap Retry.")
        case .partial(let resolved, let total, .unavailable):
            Text("\(resolved) of \(total) episodes ready. Their podcast feeds didn’t include them or couldn’t be loaded.")
        case .empty, .unknown, .complete:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch readiness {
        case .partial(_, _, let blocker):
            HStack(spacing: 16) {
                if blocker == .needsLogin, let loginFeed {
                    NavigationLink {
                        RestoreSignInDestination(feed: loginFeed)
                    } label: {
                        Text("Sign In")
                    }
                }
                if blocker != .offline {
                    retryButton
                }
            }
            .buttonStyle(.borderless)
        case .empty, .unknown, .waitingForICloud, .restoring, .complete:
            EmptyView()
        }
    }

    private var retryButton: some View {
        Button(action: onRetry) {
            if isRetrying {
                Text("Retrying…")
            } else {
                Text("Retry")
            }
        }
        .disabled(isRetrying)
        .accessibilityHint(Text("Loads the missing podcast feeds again"))
    }
}

/// Opens the podcast whose feed needs a sign-in; its detail screen hosts the
/// existing secure credential repair (#480).
private struct RestoreSignInDestination: View {
    @Query private var podcasts: [Podcast]

    init(feed: URL) {
        let target: URL? = feed
        var descriptor = FetchDescriptor<Podcast>(predicate: #Predicate<Podcast> { $0.feed == target })
        descriptor.fetchLimit = 1
        _podcasts = Query(descriptor)
    }

    var body: some View {
        if let podcast = podcasts.first {
            PodcastDetailView(podcast: podcast)
        } else {
            ContentUnavailableView("Podcast Not Found", systemImage: "questionmark.circle")
        }
    }
}

/// Re-reads restore status when hydration reports progress. Attach to the
/// view that owns a `PlaylistRestoreStatusModel`.
struct PlaylistRestoreRefreshModifier: ViewModifier {
    let model: PlaylistRestoreStatusModel
    let playlistSyncID: String
    let isDefaultQueue: Bool
    let resolvedCount: Int
    @State private var hydrationNotifications = 0

    private struct Key: Equatable {
        let syncID: String
        let resolved: Int
        let revision: Int
        let notifications: Int
    }

    func body(content: Content) -> some View {
        content
            .task(id: Key(
                syncID: playlistSyncID,
                resolved: resolvedCount,
                revision: LibraryRestoreMonitor.shared.revision,
                notifications: hydrationNotifications
            )) {
                await model.refresh(
                    playlistSyncID: playlistSyncID,
                    isDefaultQueue: isDefaultQueue,
                    resolvedCount: resolvedCount
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .splitRuntimeDidHydrate)) { _ in
                hydrationNotifications &+= 1
            }
    }
}

extension View {
    func refreshesPlaylistRestoreStatus(
        _ model: PlaylistRestoreStatusModel,
        playlistSyncID: String,
        isDefaultQueue: Bool,
        resolvedCount: Int
    ) -> some View {
        modifier(PlaylistRestoreRefreshModifier(
            model: model,
            playlistSyncID: playlistSyncID,
            isDefaultQueue: isDefaultQueue,
            resolvedCount: resolvedCount
        ))
    }
}
