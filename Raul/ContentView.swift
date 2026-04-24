//
//  ContentView.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import SwiftUI
import SwiftData
import BasicLogger
import CloudKitSyncMonitor



struct ContentView: View {
    private enum RootTab: Hashable {
        case playlist
        case inbox
        case library
        case add
    }

    private enum SidebarDestination: Hashable {
        case inbox
        case library
        case playlist(UUID)
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: [SortDescriptor(\Playlist.sortIndex, order: .forward), SortDescriptor(\Playlist.title, order: .forward)])
    private var playlists: [Playlist]

    @AppStorage("goingToBackgroundDate") var goingToBackgroundDate: Date?
    @AppStorage(PlaylistPreferenceKeys.selectedPlaylistID) private var selectedPlaylistID: String = ""
    @State private var inboxCount: Int = 0
    @State private var selectedTab: RootTab = .playlist
    @State private var sidebarSelection: SidebarDestination?
    @State private var showAddSheet: Bool = false
    @StateObject private var syncMonitor = SyncMonitor.default
    @StateObject private var cloudSyncProgress = CloudSyncProgressStore.shared
    @Bindable private var player = Player.shared
    
    @State private var search:String = ""
    @StateObject private var incomingPodcastSubscription = IncomingPodcastSubscriptionController()
    private var SETTINGgoingBackToPlayerafterBackground: Bool = true

    
    @AppStorage("lastPlayedEpisodeID") var lastPlayedEpisode:Int?

    private var visiblePlaylists: [Playlist] {
        Playlist.manualVisibleSorted(playlists)
    }

    private var preferredPlaylist: Playlist? {
        if let selectedID = Playlist.resolvePlaylistID(from: selectedPlaylistID),
           let selectedPlaylist = visiblePlaylists.first(where: { $0.id == selectedID }) {
            return selectedPlaylist
        }

        return visiblePlaylists.first(where: { $0.title == Playlist.defaultQueueTitle })
        ?? visiblePlaylists.first
    }

    private var usesSplitLayout: Bool {
#if targetEnvironment(macCatalyst)
        return true
#else
        return horizontalSizeClass == .regular
#endif
    }

    private var playlistTabTitle: String {
        preferredPlaylist?.displayTitle ?? Playlist.defaultQueueDisplayName
    }

    private var playlistTabSymbolName: String {
        preferredPlaylist?.displaySymbolName ?? Playlist.defaultQueueSymbolName
    }
    
    var body: some View {
        Group {
            if usesSplitLayout {
                splitLayout
            } else {
                compactLayout
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            cloudSyncPendingBanner
        }
        .sheet(isPresented: $player.isPlayerSheetPresented) {
            PlayerView(fullSize: true)
                .presentationDragIndicator(.visible)
                .padding(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
        .sheet(isPresented: addSheetBinding) {
            AddPodcastView(search: $search)
                .searchable(text: $search, prompt: "URL or Search")
        }

        
        .task {
            CrashBreadcrumbs.shared.record("content_view_task_started")
            cloudSyncProgress.startMonitoring(modelContext: modelContext)
            await loadInboxCount()
            _ = Playlist.ensureDefaultQueue(in: modelContext)
            if usesSplitLayout {
                ensureLargeScreenSelectionIsValid()
            }
            CrashBreadcrumbs.shared.record("content_view_task_completed")
        }
        .onChange(of: horizontalSizeClass) { _, _ in
            if usesSplitLayout {
                ensureLargeScreenSelectionIsValid()
            }
        }
        .onChange(of: visiblePlaylists.map(\.id)) { _, _ in
            if usesSplitLayout {
                ensureLargeScreenSelectionIsValid()
            }
        }
        .onChange(of: sidebarSelection) { _, newValue in
            guard case let .playlist(playlistID)? = newValue else { return }
            let nextSelectedPlaylistID = playlistID.uuidString
            if selectedPlaylistID != nextSelectedPlaylistID {
                selectedPlaylistID = nextSelectedPlaylistID
            }
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
                    Task { await cloudSyncProgress.refreshNow() }
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
        .onOpenURL { url in
            CrashBreadcrumbs.shared.record("on_open_url", details: url.absoluteString)
            if IncomingPodcastSubscriptionController.canHandle(url) {
                if usesSplitLayout {
                    showAddSheet = true
                } else {
                    selectedTab = .add
                }
                incomingPodcastSubscription.handleIncomingURL(url)
                return
            }

            guard url.scheme == "upnext" else { return }
            if usesSplitLayout {
                routeToDefaultPlaylist()
            } else {
                selectedTab = .playlist
            }
        }
        .sheet(isPresented: $incomingPodcastSubscription.isPresented, onDismiss: {
            incomingPodcastSubscription.dismiss()
        }) {
            IncomingPodcastSubscriptionView(controller: incomingPodcastSubscription)
                .presentationDetents([.medium, .large])
        }
        

    }

    @ViewBuilder
    private var compactLayout: some View {
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
    }

    @ViewBuilder
    private var cloudSyncPendingBanner: some View {
        if syncMonitor.isNotSyncing || cloudSyncProgress.shouldDisplayProgress {
            HStack(spacing: 10) {
                Image(systemName: bannerSymbolName)
                    .foregroundStyle(bannerSymbolColor)
                    .font(.headline)

                VStack(alignment: .leading, spacing: 2) {
                    Text(syncMonitor.isNotSyncing ? "iCloud Sync Not Started" : "Syncing iCloud Data")
                        .font(.subheadline.weight(.semibold))
                    Text(bannerDetailText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
    }

    private var bannerDetailText: String {
        if cloudSyncProgress.shouldDisplayProgress {
            return "Progress \(cloudSyncProgress.overallProgressText) · \(cloudSyncProgress.detailText)"
        }
        return "Data is available in iCloud, but syncing has not started on this device yet."
    }

    private var bannerSymbolName: String {
        if cloudSyncProgress.shouldDisplayProgress {
            return "arrow.trianglehead.clockwise.icloud"
        }
        return syncMonitor.syncStateSummary.symbolName
    }

    private var bannerSymbolColor: Color {
        if cloudSyncProgress.shouldDisplayProgress {
            return .secondary
        }
        return syncMonitor.syncStateSummary.symbolColor
    }

    private var splitLayout: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                Section("Browse") {
                    Label("Inbox", systemImage: "tray.fill")
                        .tag(SidebarDestination.inbox)

                    Label("Library", systemImage: "books.vertical")
                        .tag(SidebarDestination.library)
                }

                Section("Playlists") {
                    ForEach(visiblePlaylists) { playlist in
                        Label(playlist.displayTitle, systemImage: playlist.displaySymbolName)
                            .tag(SidebarDestination.playlist(playlist.id))
                    }
                }
            }
            .navigationTitle("Up Next")
        } detail: {
            Group {
                switch sidebarSelection {
                case .some(.inbox):
                    InboxView()
                case .some(.library):
                    LibraryView()
                case let .some(.playlist(playlistID)):
                    PlaylistView(fixedPlaylistID: playlistID)
                case .none:
                    ContentUnavailableView("Select a section", systemImage: "sidebar.left")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add podcast")
                    .accessibilityHint("Open add and search for podcast feeds")
                    .accessibilityInputLabels([Text("Add podcast"), Text("Search podcasts")])
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.currentEpisode != nil {
                PlayerTabBarView()
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .background(.bar)
            }
        }
    }

    private var addSheetBinding: Binding<Bool> {
        Binding(
            get: {
                showAddSheet && incomingPodcastSubscription.isPresented == false
            },
            set: { newValue in
                showAddSheet = newValue
            }
        )
    }

    private func ensureLargeScreenSelectionIsValid() {
        switch sidebarSelection {
        case let .some(.playlist(playlistID)):
            guard visiblePlaylists.contains(where: { $0.id == playlistID }) else {
                routeToDefaultPlaylist()
                return
            }
            selectedPlaylistID = playlistID.uuidString
        case .some(.inbox), .some(.library):
            break
        case .none:
            routeToDefaultPlaylist()
        }
    }

    private func routeToDefaultPlaylist() {
        if let playlist = preferredPlaylist {
            sidebarSelection = .playlist(playlist.id)
            selectedPlaylistID = playlist.id.uuidString
        } else {
            sidebarSelection = .inbox
        }
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
        
}

#Preview {
    ContentView()
        .modelContainer(for: Podcast.self, inMemory: true, isAutosaveEnabled: true)
}
