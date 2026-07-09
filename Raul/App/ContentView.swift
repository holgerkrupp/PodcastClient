//
//  ContentView.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import SwiftUI
import SwiftData
import BasicLogger



struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: [SortDescriptor(\Playlist.sortIndex, order: .forward), SortDescriptor(\Playlist.title, order: .forward)])
    private var playlists: [Playlist]
    @Query(filter: #Predicate<Podcast> { $0.metaData?.isSubscribed != false })
    private var subscribedPodcasts: [Podcast]

    @AppStorage("goingToBackgroundDate") var goingToBackgroundDate: Date?
    @AppStorage(OnboardingPreferenceKeys.didCompleteOnboarding) private var didCompleteOnboarding: Bool = false
    @AppStorage(PlaylistPreferenceKeys.selectedPlaylistID) private var selectedPlaylistID: String = ""
    @SceneStorage("mainWindow.selectedSection") private var restoredSelection = AppSection.queue.rawValue
    @State private var inboxCount: Int = 0
    @State private var navigation = AppNavigationModel()
    @State private var didRestoreSelection = false
    @State private var showOnboarding: Bool = false
    @State private var didEvaluateOnboardingLaunch = false
    @StateObject private var podcastYearShareCoordinator = PodcastYearShareCoordinator()
    
    @State private var search:String = ""
    @StateObject private var incomingPodcastSubscription = IncomingPodcastSubscriptionController()
    private var SETTINGgoingBackToPlayerafterBackground: Bool = true

    
    @AppStorage("lastPlayedEpisodeID") var lastPlayedEpisode:Int?

    private var playlistTabMetadata: (title: String, symbolName: String) {
        let visiblePlaylists = Playlist.manualVisibleSorted(playlists)

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
        let currentPlaylistTabMetadata = playlistTabMetadata

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
        .hostsPlayerPresentation(navigation: navigation)
#if os(macOS) || targetEnvironment(macCatalyst)
        .focusedSceneValue(\.appNavigationModel, navigation)
#endif
        .task {
            CrashBreadcrumbs.shared.record("content_view_task_started")
            await loadInboxCount()
            await importPendingSharedEpisodeIfNeeded()
            await podcastYearShareCoordinator.evaluateAppLaunch(modelContext: modelContext)
            CrashBreadcrumbs.shared.record("content_view_task_completed")
        }
        .onChange(of: phase, {
            SystemPressureGate.shared.setSceneActive(phase == .active)
            if SETTINGgoingBackToPlayerafterBackground{
                switch phase {
                case .background:
                    CrashBreadcrumbs.shared.record("scene_phase_background")
                    setGoingToBackgroundDate()
                   
                case .active:
                    CrashBreadcrumbs.shared.record("scene_phase_active")
                    // Refresh the badge when app becomes active
                    Task { await loadInboxCount() }
                    Task { await importPendingSharedEpisodeIfNeeded() }
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
        .onChange(of: navigation.selectedSection) { _, newValue in
            restoredSelection = newValue.rawValue
        }
        .onOpenURL { url in
            CrashBreadcrumbs.shared.record("on_open_url", details: url.absoluteString)
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
        .sheet(isPresented: $showOnboarding, onDismiss: {
            didCompleteOnboarding = true
        }) {
            OnboardingView(
                requiresInitialCloudImport: ModelContainerManager.shared.requiresInitialCloudImport,
                modelContainer: modelContext.container
            )
                .interactiveDismissDisabled()
        }
        .onChange(of: subscribedPodcastCount) { _, _ in
            evaluateOnboardingLaunchIfNeeded()
        }
        .onAppear {
            if didRestoreSelection == false {
                navigation.selectedSection = AppNavigationModel.restoredSection(from: restoredSelection)
                didRestoreSelection = true
            }
            evaluateOnboardingLaunchIfNeeded()
        }
        

    }

    private var subscribedPodcastCount: Int {
        subscribedPodcasts.count
    }

    private var usesSidebarLayout: Bool {
        PlatformSupport.usesDesktopLayout || horizontalSizeClass == .regular
    }
    
    func setGoingToBackgroundDate() {
        goingToBackgroundDate = Date()
    }
    
    // MARK: - Manual count loader
    @MainActor
    private func loadInboxCount() async {
        CrashBreadcrumbs.shared.record("load_inbox_count_started")
        let counter = InboxCountLoader(container: modelContext.container)

        do {
            inboxCount = try await counter.count()
            CrashBreadcrumbs.shared.record("load_inbox_count_success", details: "count=\(inboxCount)")
        } catch {
            BasicLogger.shared.log("Failed to load inbox count: \(error.localizedDescription) | breadcrumbs: \(CrashBreadcrumbs.shared.recentSummary())")
            CrashBreadcrumbs.shared.record("load_inbox_count_failed", details: error.localizedDescription)
            inboxCount = 0
        }
    }

    @MainActor
    private func importPendingSharedEpisodeIfNeeded() async {
        guard let sharedEpisodeURL = PendingSharedEpisodeImportStore.pendingURL() else {
            return
        }

        await importSharedEpisode(from: sharedEpisodeURL)
    }

    @MainActor
    private func importSharedEpisode(from sharedEpisodeURL: URL) async {
        navigation.select(.inbox)
        do {
            let importedURL = try await PodcastEpisodeShareImporter().importEpisode(
                from: sharedEpisodeURL,
                modelContext: modelContext
            )
            PendingSharedEpisodeImportStore.clear(ifMatching: sharedEpisodeURL)
            CrashBreadcrumbs.shared.record("shared_episode_imported", details: importedURL.absoluteString)
            BasicLogger.shared.log("Imported shared episode: \(importedURL.absoluteString)")
            await loadInboxCount()
        } catch {
            BasicLogger.shared.log("Failed to import shared episode \(sharedEpisodeURL.absoluteString): \(error.localizedDescription)")
            CrashBreadcrumbs.shared.record("shared_episode_import_failed", details: error.localizedDescription)
        }
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
        didEvaluateOnboardingLaunch = true

        if subscribedPodcastCount > 0 {
            didCompleteOnboarding = true
            return
        }

        if didCompleteOnboarding == false {
            showOnboarding = true
        }
    }

}

private actor InboxCountLoader {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func count() throws -> Int {
        let context = ModelContext(container)
        let predicate = #Predicate<EpisodeMetaData> { $0.isInbox == true }
        return try context.fetchCount(FetchDescriptor<EpisodeMetaData>(predicate: predicate))
    }
}

private enum PendingSharedEpisodeImportStore {
    private static let appGroupID = "group.de.holgerkrupp.PodcastClient"
    private static let pendingURLKey = "PendingSharedEpisodeURL"

    static func pendingURL() -> URL? {
        guard let rawValue = UserDefaults(suiteName: appGroupID)?.string(forKey: pendingURLKey) else {
            return nil
        }
        guard let url = URL(string: rawValue), isSupportedSharedURL(url) else {
            clear()
            return nil
        }

        return url
    }

    static func clear(ifMatching url: URL) {
        let defaults = UserDefaults(suiteName: appGroupID)
        guard defaults?.string(forKey: pendingURLKey) == url.absoluteString else {
            return
        }
        defaults?.removeObject(forKey: pendingURLKey)
        defaults?.synchronize()
    }

    static func clear() {
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.removeObject(forKey: pendingURLKey)
        defaults?.synchronize()
    }

    private static func isSupportedSharedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        return scheme == "http"
            || scheme == "https"
            || scheme == "feed"
            || scheme == "rss"
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Podcast.self, inMemory: true, isAutosaveEnabled: true)
}
