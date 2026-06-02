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
    private enum RootTab: Hashable {
        case playlist
        case inbox
        case library
        case add
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var phase
    @Query(sort: [SortDescriptor(\Playlist.sortIndex, order: .forward), SortDescriptor(\Playlist.title, order: .forward)])
    private var playlists: [Playlist]
    @Query private var podcasts: [Podcast]

    @AppStorage("goingToBackgroundDate") var goingToBackgroundDate: Date?
    @AppStorage(OnboardingPreferenceKeys.didCompleteOnboarding) private var didCompleteOnboarding: Bool = false
    @AppStorage(PlaylistPreferenceKeys.selectedPlaylistID) private var selectedPlaylistID: String = ""
    @State private var inboxCount: Int = 0
    @State private var selectedTab: RootTab = .playlist
    @State private var showOnboarding: Bool = false
    @State private var didEvaluateOnboardingLaunch = false
    @StateObject private var podcastYearShareCoordinator = PodcastYearShareCoordinator()
    @Bindable private var player = Player.shared
    
    @State private var search:String = ""
    @StateObject private var incomingPodcastSubscription = IncomingPodcastSubscriptionController()
    private var SETTINGgoingBackToPlayerafterBackground: Bool = true

    
    @AppStorage("lastPlayedEpisodeID") var lastPlayedEpisode:Int?

    private var playlistTabTitle: String {
        let visiblePlaylists = Playlist.manualVisibleSorted(playlists)

        if let selectedID = UUID(uuidString: selectedPlaylistID),
           let selectedPlaylist = visiblePlaylists.first(where: { $0.id == selectedID }) {
            return selectedPlaylist.displayTitle
        }

        if let defaultPlaylist = visiblePlaylists.first(where: { $0.title == Playlist.defaultQueueTitle }) {
            return defaultPlaylist.displayTitle
        }

        return Playlist.defaultQueueDisplayName
    }

    private var playlistTabSymbolName: String {
        let visiblePlaylists = Playlist.manualVisibleSorted(playlists)

        if let selectedID = UUID(uuidString: selectedPlaylistID),
           let selectedPlaylist = visiblePlaylists.first(where: { $0.id == selectedID }) {
            return selectedPlaylist.displaySymbolName
        }

        if let defaultPlaylist = visiblePlaylists.first(where: { $0.title == Playlist.defaultQueueTitle }) {
            return defaultPlaylist.displaySymbolName
        }

        return Playlist.defaultQueueSymbolName
    }
    
    var body: some View {
        
        TabView(selection: $selectedTab) {
            
            Tab(LocalizedStringKey(playlistTabTitle), systemImage: playlistTabSymbolName, value: RootTab.playlist) {
                PlaylistView()
            }
          
            Tab("Inbox", systemImage: "tray.fill", value: RootTab.inbox) {
                InboxView()
            }
            .badge(inboxCount)

            Tab("Library", systemImage: "books.vertical", value: RootTab.library) {
                LibraryView()
            }

            
            Tab("Add", systemImage: "plus", value: RootTab.add, role: .search) {
                AddPodcastView(search: $search)
                    .searchable(text: $search, prompt: "URL or Search")
            }
            

            
        }
       
        .tabBarMinimizeBehavior(.onScrollDown)
        
        .tabViewBottomAccessory {
            PlayerTabBarView()
        }
        .sheet(isPresented: $player.isPlayerSheetPresented) {
            PlayerView(fullSize: true)
                .presentationDragIndicator(.visible)
                .padding(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }

        
        .task {
            CrashBreadcrumbs.shared.record("content_view_task_started")
            await loadInboxCount()
            await importPendingSharedEpisodeIfNeeded()
            await podcastYearShareCoordinator.evaluateAppLaunch(modelContext: modelContext)
            CrashBreadcrumbs.shared.record("content_view_task_completed")
        }
        .onChange(of: phase, {
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
        .onOpenURL { url in
            CrashBreadcrumbs.shared.record("on_open_url", details: url.absoluteString)
            if IncomingPodcastSubscriptionController.canHandle(url) {
                selectedTab = .add
                incomingPodcastSubscription.handleIncomingURL(url)
                return
            }

            if PodcastYearShareCoordinator.isPodcastYearURL(url) {
                selectedTab = .library
                Task {
                    _ = await podcastYearShareCoordinator.handleOpenURL(url, modelContext: modelContext)
                }
                return
            }

            guard url.scheme == "upnext" else { return }
            if let sharedEpisodeURL = sharedEpisodeURL(from: url) {
                Task {
                    await importSharedEpisode(from: sharedEpisodeURL)
                }
                return
            }

            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let playlistID = components.queryItems?.first(where: { $0.name == "playlistID" })?.value,
               UUID(uuidString: playlistID) != nil {
                selectedPlaylistID = playlistID
            }
            selectedTab = .playlist
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
            OnboardingView()
                .interactiveDismissDisabled()
        }
        .onChange(of: subscribedPodcastCount) { _, _ in
            evaluateOnboardingLaunchIfNeeded()
        }
        .onAppear {
            evaluateOnboardingLaunchIfNeeded()
        }
        

    }

    private var subscribedPodcastCount: Int {
        podcasts.filter(\.isSubscribed).count
    }
    
    func setGoingToBackgroundDate() {
        goingToBackgroundDate = Date()
    }
    
    // MARK: - Manual count loader
    @MainActor
    private func loadInboxCount() async {
        CrashBreadcrumbs.shared.record("load_inbox_count_started")
        let predicate = #Predicate<EpisodeMetaData> { $0.isInbox == true }
        let descriptor = FetchDescriptor<EpisodeMetaData>(predicate: predicate)

        do {
            inboxCount = try modelContext.fetch(descriptor).count
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
        selectedTab = .inbox
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

    private func sharedEpisodeURL(from url: URL) -> URL? {
        guard url.host() == "shareEpisode",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawURL = components.queryItems?.first(where: { $0.name == "url" })?.value else {
            return nil
        }

        return URL(string: rawURL)
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
