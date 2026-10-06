//
//  ContentView.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import SwiftUI
import SwiftData
import StoreKit
import ESADesignKit



struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.requestReview) private var requestReview
    @Query(sort: [SortDescriptor(\Playlist.sortIndex, order: .forward), SortDescriptor(\Playlist.title, order: .forward)])
    private var playlists: [Playlist]

    @AppStorage("goingToBackgroundDate") var goingToBackgroundDate: Date?
    @AppStorage(OnboardingPreferenceKeys.didCompleteOnboarding) private var didCompleteOnboarding: Bool = false
    @AppStorage(UpNextVisualDesignPreference.whatsNewAcknowledgementKey) private var didAcknowledgeVisualDesignWhatsNew = false
    @AppStorage(PlaylistPreferenceKeys.selectedPlaylistID) private var selectedPlaylistID: String = ""
    @SceneStorage("mainWindow.selectedSection") private var restoredSelection = AppSection.queue.rawValue
    @State private var inboxCount: Int = 0
    @State private var subscribedPodcastCount: Int?
    @State private var navigation = AppNavigationModel()
    @State private var didRestoreSelection = false
    @State private var showOnboarding: Bool = false
    @State private var showVisualDesignWhatsNew = false
    @State private var didEvaluateOnboardingLaunch = false
    @State private var didCompleteInitialContentLoad = false
    @State private var isImportingSharedEpisodes = false
    @State private var sharedEpisodeRecovery: SharedEpisodeRecovery?
    @StateObject private var podcastYearShareCoordinator = PodcastYearShareCoordinator()
    
    @State private var search:String = ""
    @StateObject private var incomingPodcastSubscription = IncomingPodcastSubscriptionController()
    private var SETTINGgoingBackToPlayerafterBackground: Bool = true

    
    @AppStorage("lastPlayedEpisodeID") var lastPlayedEpisode:Int?

    private func playlistTabMetadata(
        from visiblePlaylists: [Playlist]
    ) -> (title: String, symbolName: String) {
        if let selectedID = UUID(uuidString: selectedPlaylistID),
           let selectedPlaylist = visiblePlaylists.first(where: { $0.id == selectedID }) {
            return (selectedPlaylist.displayTitle, selectedPlaylist.displaySymbolName)
        }

        if let defaultPlaylist = visiblePlaylists.first(where: { $0.title == Playlist.defaultQueueTitle }) {
            return (defaultPlaylist.displayTitle, defaultPlaylist.displaySymbolName)
        }

        return (Playlist.defaultQueueDisplayName, Playlist.defaultQueueSymbolName)
    }
    
    var body: some View {
        let visiblePlaylists = Playlist.manualVisibleSorted(playlists)
        let currentPlaylistTabMetadata = playlistTabMetadata(from: visiblePlaylists)
        let episodeControlPlaylists = visiblePlaylists.map {
            EpisodeControlPlaylist(playlist: $0)
        }

        Group {
            if usesSidebarLayout {
                SidebarAppShell(
                    navigation: navigation,
                    inboxCount: inboxCount,
                    search: $search
                )
            } else {
                CompactAppShell(
                    navigation: navigation,
                    inboxCount: inboxCount,
                    playlistTitle: currentPlaylistTabMetadata.title,
                    playlistSymbolName: currentPlaylistTabMetadata.symbolName,
                    search: $search
                )
            }
        }
        .environment(\.episodeControlPlaylists, episodeControlPlaylists)
        .hostsPlayerPresentation(navigation: navigation)
#if os(macOS) || targetEnvironment(macCatalyst)
        .focusedSceneValue(\.appNavigationModel, navigation)
#endif
        .task {
            CrashBreadcrumbs.shared.record("content_view_task_started")
            await loadLaunchCounts()
            await importPendingSharedEpisodeIfNeeded()
            didCompleteInitialContentLoad = true
            try? await Task.sleep(for: .seconds(4))
            guard Task.isCancelled == false else { return }
            await podcastYearShareCoordinator.evaluateAppLaunch(modelContext: modelContext)
            CrashBreadcrumbs.shared.record("content_view_task_completed")
        }
        .task(id: phase) {
            await considerRequestingAppReview()
        }
        .task(id: visualDesignPresentationSignature) {
            evaluateVisualDesignWhatsNewIfNeeded()
        }
        .onChange(of: phase, {
            SystemPressureGate.shared.setSceneActive(phase == .active)
            if phase == .active, didCompleteInitialContentLoad {
                Task { await importPendingSharedEpisodeIfNeeded() }
            }
            if SETTINGgoingBackToPlayerafterBackground{
                switch phase {
                case .background:
                    CrashBreadcrumbs.shared.record("scene_phase_background")
                    setGoingToBackgroundDate()
                   
                case .active:
                    CrashBreadcrumbs.shared.record("scene_phase_active")
                    guard didCompleteInitialContentLoad else { break }
                    // Refresh the badge when app becomes active
                    Task { await loadInboxCount() }
                    Task { await podcastYearShareCoordinator.evaluateAppBecameActive(modelContext: modelContext) }
                    if let goingToBackgroundDate = goingToBackgroundDate, goingToBackgroundDate < Date().addingTimeInterval(-5*60) {
                       
                        //    selectedTab = .timeline
                       
                    }
                    
                default: break
                }
            }
        })
        // React to inbox change notifications anywhere in the app
        .onReceive(NotificationCenter.default.publisher(for: .inboxDidChange)) { _ in
            print("inbox Changed")
            CrashBreadcrumbs.shared.record("inbox_did_change_notification")
            Task { await loadInboxCount() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .podcastYearShareNotificationTapped)) { _ in
            Task {
                await podcastYearShareCoordinator.handleNotificationTap(modelContext: modelContext)
            }
        }
        .onChange(of: selectedPlaylistID) { _, newValue in
            refreshWidgetForSelectedPlaylist(newValue)
        }
        .task(id: sharedPlaylistSnapshotSignature) {
            PendingSharedEpisodeImportStore.publish(playlists: playlists)
        }
        .onChange(of: navigation.selectedSection) { _, newValue in
            restoredSelection = newValue.rawValue
        }
        .onOpenURL { url in
            CrashBreadcrumbs.shared.record("on_open_url", details: url.redactedPodcastURLString)
            guard let appLink = AppLink.parse(url) else { return }

            switch appLink {
            case .podcastYear(let url):
                navigation.select(.library)
                Task {
                    _ = await podcastYearShareCoordinator.handleOpenURL(url, modelContext: modelContext)
                }
            case .playEpisode(let episodeURL):
                Task {
                    await Player.shared.playEpisode(episodeURL, playDirectly: true)
                }
            case .showEpisode(let episodeURL, let playlistID):
                if let playlistID {
                    selectedPlaylistID = playlistID
                }
                navigation.openPlaylistEpisode(episodeURL)
            case .importSharedEpisode(let sharedEpisodeURL):
                Task {
                    await importSharedEpisode(from: sharedEpisodeURL)
                }
            case .selectQueue(let playlistID):
                if let playlistID {
                    selectedPlaylistID = playlistID
                }
                navigation.select(.queue)
            case .incomingSubscription(let url):
                navigation.select(.search)
                incomingPodcastSubscription.handleIncomingURL(url)
            }
        }
        .sheet(isPresented: $incomingPodcastSubscription.isPresented, onDismiss: {
            incomingPodcastSubscription.dismiss()
        }) {
            IncomingPodcastSubscriptionView(controller: incomingPodcastSubscription)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $podcastYearShareCoordinator.sheetRequest) { request in
            PodcastYearShareSheet(request: request)
        }
        .sheet(item: $sharedEpisodeRecovery) { recovery in
            SharedEpisodeRecoveryView(recovery: recovery) { action in
                handleRecovery(action, for: recovery)
            }
        }
        .sheet(isPresented: $showOnboarding, onDismiss: {
            didCompleteOnboarding = true
            didAcknowledgeVisualDesignWhatsNew = true
            evaluateVisualDesignWhatsNewIfNeeded()
        }) {
            OnboardingView(
                requiresInitialCloudImport: ModelContainerManager.shared.requiresInitialCloudImport,
                modelContainer: modelContext.container
            )
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showVisualDesignWhatsNew, onDismiss: {
            evaluateVisualDesignWhatsNewIfNeeded()
        }) {
            VisualDesignWhatsNewSheet {
                didAcknowledgeVisualDesignWhatsNew = true
                showVisualDesignWhatsNew = false
            }
            .interactiveDismissDisabled()
        }
        .onChange(of: subscribedPodcastCount) { _, _ in
            evaluateOnboardingLaunchIfNeeded()
            evaluateVisualDesignWhatsNewIfNeeded()
        }
        .onAppear {
            if didRestoreSelection == false {
                navigation.selectedSection = AppNavigationModel.restoredSection(from: restoredSelection)
                didRestoreSelection = true
            }
            evaluateOnboardingLaunchIfNeeded()
            evaluateVisualDesignWhatsNewIfNeeded()
        }
        

    }

    private var usesSidebarLayout: Bool {
        PlatformSupport.usesDesktopLayout
            || horizontalSizeClass == .regular
    }
    
    func setGoingToBackgroundDate() {
        goingToBackgroundDate = Date()
    }

    @MainActor
    private func considerRequestingAppReview() async {
        guard phase == .active else { return }

        let foregroundStartedAt = Date()
        do {
            try await Task.sleep(for: .seconds(AppReviewPromptPolicy.minimumForegroundDuration))
        } catch {
            return
        }

        guard Task.isCancelled == false, phase == .active else { return }
        let manager = ModelContainerManager.shared
        let loader = AppReviewLifetimeListeningLoader(
            legacyContainer: modelContext.container,
            userStateContainer: manager.preparedUserStateContainer,
            useSyncedStore: StoreDevelopmentConfiguration.newStoreReadsEnabled
        )
        let listeningSeconds = await loader.totalSeconds()
        guard Task.isCancelled == false, phase == .active else { return }

        let now = Date()
        let hasBlockingPresentation = showOnboarding
            || incomingPodcastSubscription.isPresented
            || podcastYearShareCoordinator.sheetRequest != nil
            || navigation.isPlayerPresented
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let store = AppReviewPromptStore()
        guard AppReviewPromptPolicy.shouldRequestReview(
            listeningSeconds: listeningSeconds,
            foregroundDuration: now.timeIntervalSince(foregroundStartedAt),
            isSceneActive: phase == .active,
            hasBlockingPresentation: hasBlockingPresentation,
            currentVersion: version,
            state: store.state,
            now: now
        ) else {
            return
        }

        // StoreKit doesn't report whether its system-controlled prompt was
        // displayed, so record the attempt before handing control to it.
        store.recordRequest(version: version, at: now)
        CrashBreadcrumbs.shared.record(
            "app_review_requested",
            details: "version=\(version),listening_hours=\(Int(listeningSeconds / 3_600))"
        )
        requestReview()
    }
    
    // MARK: - Manual count loader
    @MainActor
    private func loadLaunchCounts() async {
        // Keep relationship-heavy badge queries out of the first scene
        // transition and behind the runtime-store readiness barrier.
        await ModelContainerManager.shared.waitUntilApplicationQueriesReady()
        try? await Task.sleep(for: .milliseconds(250))
        guard Task.isCancelled == false else { return }
        let loader = AppLaunchCountLoader(modelContainer: modelContext.container)
        do {
            let counts = try await loader.counts()
            inboxCount = counts.inbox
            subscribedPodcastCount = counts.subscribedPodcasts
            evaluateOnboardingLaunchIfNeeded()
            CrashBreadcrumbs.shared.record(
                "launch_counts_loaded",
                details: "inbox=\(counts.inbox),subscriptions=\(counts.subscribedPodcasts)"
            )
        } catch {
            AppDiagnostics.log("Failed to load launch counts: \(error.localizedDescription)")
            inboxCount = 0
            subscribedPodcastCount = 0
            evaluateOnboardingLaunchIfNeeded()
        }
    }

    @MainActor
    private func loadInboxCount() async {
        await ModelContainerManager.shared.waitUntilApplicationQueriesReady()
        guard Task.isCancelled == false else { return }
        CrashBreadcrumbs.shared.record("load_inbox_count_started")
        let counter = InboxCountLoader.shared

        do {
            inboxCount = try await counter.count(in: modelContext.container)
            CrashBreadcrumbs.shared.record("load_inbox_count_success", details: "count=\(inboxCount)")
        } catch {
            AppDiagnostics.log("Failed to load inbox count: \(error.localizedDescription) | breadcrumbs: \(CrashBreadcrumbs.shared.recentSummary())")
            CrashBreadcrumbs.shared.record("load_inbox_count_failed", details: error.localizedDescription)
            inboxCount = 0
        }
    }

    @MainActor
    private func importPendingSharedEpisodeIfNeeded() async {
        guard isImportingSharedEpisodes == false else { return }
        let actions = PendingSharedEpisodeImportStore.pendingActions()
        guard actions.isEmpty == false else { return }

        isImportingSharedEpisodes = true
        defer { isImportingSharedEpisodes = false }

        for action in actions {
            await handlePendingSharedEpisodeAction(action)
        }
    }

    @MainActor
    private func handlePendingSharedEpisodeAction(_ action: PendingSharedEpisodeAction) async {
        switch action.kind {
        case .search:
            PendingSharedEpisodeImportStore.remove(id: action.id)
            navigation.select(.search)
            search = action.query ?? action.url.host() ?? action.url.absoluteString

        case .subscribe:
            PendingSharedEpisodeImportStore.remove(id: action.id)
            guard let feedURL = action.feedURL else {
                presentSharedEpisodeRecovery(for: action.url, message: "The podcast feed was not available.")
                return
            }
            navigation.select(.search)
            incomingPodcastSubscription.handleIncomingURL(feedURL)

        case .importEpisode:
            await importSharedEpisode(
                PendingSharedEpisodeImportRequest(id: action.id, url: action.url, playlistID: action.playlistID)
            )
        }
    }

    @MainActor
    private func importSharedEpisode(from sharedEpisodeURL: URL) async {
        navigation.select(.inbox)
        do {
            let importedURL = try await PodcastEpisodeShareImporter().importEpisode(
                from: sharedEpisodeURL,
                modelContext: modelContext
            )
            CrashBreadcrumbs.shared.record("shared_episode_imported", details: importedURL.redactedPodcastURLString)
            AppDiagnostics.log("Imported shared episode: \(importedURL.redactedPodcastURLString)")
            await loadInboxCount()
        } catch {
            AppDiagnostics.log("Failed to import shared episode \(sharedEpisodeURL.redactedPodcastURLString): \(error.localizedDescription)")
            CrashBreadcrumbs.shared.record("shared_episode_import_failed", details: error.localizedDescription)
            presentSharedEpisodeRecovery(for: sharedEpisodeURL, message: error.localizedDescription)
        }
    }

    @MainActor
    private func importSharedEpisode(_ request: PendingSharedEpisodeImportRequest) async {
        let destination: SharedEpisodeImportDestination
        if let playlistID = request.playlistID,
           Playlist.manualVisibleSorted(playlists).contains(where: {
               $0.id == playlistID
           }) {
            destination = .playlist(playlistID)
            selectedPlaylistID = playlistID.uuidString
            navigation.select(.queue)
        } else {
            destination = .inbox
            navigation.select(.inbox)
        }

        do {
            let importedURL = try await PodcastEpisodeShareImporter().importEpisode(
                from: request.url,
                destination: destination,
                modelContext: modelContext
            )
            PendingSharedEpisodeImportStore.remove(id: request.id)
            CrashBreadcrumbs.shared.record(
                "shared_episode_imported",
                details: importedURL.redactedPodcastURLString
            )
            AppDiagnostics.log(
                "Imported shared episode: \(importedURL.redactedPodcastURLString)"
            )
            await loadInboxCount()
        } catch {
            // Consume a failed action before presenting recovery. A broken URL
            // must not run again on every scene activation.
            PendingSharedEpisodeImportStore.remove(id: request.id)
            AppDiagnostics.log(
                "Failed to import shared episode \(request.url.redactedPodcastURLString): \(error.localizedDescription)"
            )
            CrashBreadcrumbs.shared.record(
                "shared_episode_import_failed",
                details: error.localizedDescription
            )
            presentSharedEpisodeRecovery(for: request.url, message: error.localizedDescription)
        }
    }

    private func presentSharedEpisodeRecovery(for url: URL, message: String) {
        sharedEpisodeRecovery = SharedEpisodeRecovery(
            url: url,
            message: message,
            suggestedSearch: PodcastEpisodeShareImporter().fallbackSearchQueryForRecovery(url)
        )
    }

    @MainActor
    private func handleRecovery(_ action: SharedEpisodeRecoveryAction, for recovery: SharedEpisodeRecovery) {
        switch action {
        case .search:
            sharedEpisodeRecovery = nil
            navigation.select(.search)
            search = recovery.suggestedSearch ?? recovery.url.host() ?? recovery.url.absoluteString
        case .retry:
            sharedEpisodeRecovery = nil
            Task { await importSharedEpisode(from: recovery.url) }
        case .openBrowser, .dismiss:
            sharedEpisodeRecovery = nil
        }
    }

    private var sharedPlaylistSnapshotSignature: String {
        Playlist.manualVisibleSorted(playlists).map {
            [
                $0.id.uuidString,
                $0.displayTitle,
                $0.displaySymbolName,
                String($0.sortIndex)
            ].joined(separator: "|")
        }.joined(separator: "||")
    }

    private func refreshWidgetForSelectedPlaylist(_ playlistID: String) {
        guard let selectedID = Playlist.resolvePlaylistID(from: playlistID) else {
            Task {
                await PlayNextWidgetSync.refresh(using: modelContext.container)
            }
            return
        }

        Task {
            await PlayNextWidgetSync.refresh(
                using: modelContext.container,
                playlistIDs: Set([selectedID])
            )
        }
    }

    private func evaluateOnboardingLaunchIfNeeded() {
        guard didEvaluateOnboardingLaunch == false else { return }
        guard let subscribedPodcastCount else { return }
        didEvaluateOnboardingLaunch = true

        if subscribedPodcastCount > 0 {
            didCompleteOnboarding = true
            return
        }

        if didCompleteOnboarding == false {
            showOnboarding = true
        }
    }

    private func evaluateVisualDesignWhatsNewIfNeeded() {
        guard didCompleteOnboarding,
              didAcknowledgeVisualDesignWhatsNew == false,
              showOnboarding == false,
              incomingPodcastSubscription.isPresented == false,
              podcastYearShareCoordinator.sheetRequest == nil,
              sharedEpisodeRecovery == nil,
              navigation.isPlayerPresented == false else { return }
        showVisualDesignWhatsNew = true
    }

    private var visualDesignPresentationSignature: String {
        [
            String(didCompleteOnboarding),
            String(didAcknowledgeVisualDesignWhatsNew),
            String(showOnboarding),
            String(incomingPodcastSubscription.isPresented),
            String(podcastYearShareCoordinator.sheetRequest != nil),
            String(sharedEpisodeRecovery != nil),
            String(navigation.isPlayerPresented),
            String(phase == .active)
        ].joined(separator: ":")
    }

}

private struct AppLaunchCounts: Sendable {
    let inbox: Int
    let subscribedPodcasts: Int
}

@ModelActor
private actor AppLaunchCountLoader {
    func counts() throws -> AppLaunchCounts {
        let inboxPredicate = #Predicate<EpisodeMetaData> { $0.isInbox == true }
        // Count the scalar metadata row instead of traversing Podcast.metaData
        // for every object while SwiftData/CloudKit is settling.
        let subscriptionPredicate = #Predicate<PodcastMetaData> {
            $0.isSubscribed == true
        }
        return AppLaunchCounts(
            inbox: try modelContext.fetchCount(
                FetchDescriptor<EpisodeMetaData>(predicate: inboxPredicate)
            ),
            subscribedPodcasts: try modelContext.fetchCount(
                FetchDescriptor<PodcastMetaData>(predicate: subscriptionPredicate)
            )
        )
    }
}

private actor InboxCountLoader {
    static let shared = InboxCountLoader()
    private var inFlight: Task<Int, Error>?

    func count(in container: ModelContainer) async throws -> Int {
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            let predicate = #Predicate<EpisodeMetaData> { $0.isInbox == true }
            return try context.fetchCount(
                FetchDescriptor<EpisodeMetaData>(predicate: predicate)
            )
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Podcast.self, inMemory: true, isAutosaveEnabled: true)
}
