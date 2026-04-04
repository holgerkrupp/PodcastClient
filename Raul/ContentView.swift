//
//  ContentView.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import SwiftUI
import SwiftData
import BasicLogger
import CloudKit



struct ContentView: View {
    private enum RootTab: Hashable {
        case playlist
        case inbox
        case library
        case add
    }

    private enum SidebarDestination: Hashable {
        case queue
        case inbox
        case library
        case search
        case downloads
        case bookmarks
        case history
        case settings

        var title: String {
            switch self {
            case .queue: return "Queue"
            case .inbox: return "Inbox"
            case .library: return "Library"
            case .search: return "Search"
            case .downloads: return "Downloads"
            case .bookmarks: return "Bookmarks"
            case .history: return "History"
            case .settings: return "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .queue: return "calendar.day.timeline.leading"
            case .inbox: return "tray.fill"
            case .library: return "books.vertical"
            case .search: return "magnifyingglass"
            case .downloads: return "arrow.down.circle"
            case .bookmarks: return "bookmark"
            case .history: return "clock.arrow.circlepath"
            case .settings: return "gearshape"
            }
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Query(sort: \Podcast.title) private var podcasts: [Podcast]
    @Query(filter: #Predicate<PlaylistEntry> { $0.playlist?.title == "de.holgerkrupp.podbay.queue" })
    private var upNextEntries: [PlaylistEntry]

    @AppStorage("goingToBackgroundDate") var goingToBackgroundDate: Date?
    @State private var inboxCount: Int = 0
    @State private var selectedTab: RootTab = .playlist
    @State private var selectedSidebarDestination: SidebarDestination? = .queue
    @State private var expectedRemoteLibraryData = false
    @State private var cloudAccountAvailable = false
    
    @State private var search:String = ""
    @StateObject private var incomingPodcastSubscription = IncomingPodcastSubscriptionController()
    private var SETTINGgoingBackToPlayerafterBackground: Bool = true

    
    @AppStorage("lastPlayedEpisodeID") var lastPlayedEpisode:Int?

    private var shouldUseSidebarLayout: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
#else
        horizontalSizeClass != .compact
#endif
    }

    private var hasLocalLibraryData: Bool {
        podcasts.isEmpty == false || upNextEntries.isEmpty == false
    }

    private var shouldShowCloudSyncHint: Bool {
        hasLocalLibraryData == false && (expectedRemoteLibraryData || cloudAccountAvailable)
    }
    
    var body: some View {
        Group {
            if shouldUseSidebarLayout {
                iPadSidebarLayout
            } else {
                compactPhoneLayout
            }
        }
        .task {
            await loadInboxCount()
            if hasLocalLibraryData {
                CloudSyncExpectationStore.publishExpectedSnapshot(using: modelContext)
            }
            refreshCloudSyncExpectation()
            await refreshCloudAccountStatus()
        }
        .onChange(of: phase, {
            if SETTINGgoingBackToPlayerafterBackground{
                switch phase {
                case .background:
                    setGoingToBackgroundDate()
                   
                case .active:
                    // Refresh the badge when app becomes active
                    Task { await loadInboxCount() }
                    Task { await refreshCloudAccountStatus() }
                    if hasLocalLibraryData {
                        CloudSyncExpectationStore.publishExpectedSnapshot(using: modelContext)
                    }
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
            Task { await loadInboxCount() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
            refreshCloudSyncExpectation()
        }
        .onChange(of: hasLocalLibraryData) { _, hasData in
            if hasData {
                CloudSyncExpectationStore.publishExpectedSnapshot(using: modelContext)
            }
            refreshCloudSyncExpectation()
        }
        .onOpenURL { url in
            if IncomingPodcastSubscriptionController.canHandle(url) {
                selectedTab = .add
                selectedSidebarDestination = .search
                incomingPodcastSubscription.handleIncomingURL(url)
                return
            }

            guard url.scheme == "upnext" else { return }
            selectedTab = .playlist
            selectedSidebarDestination = .queue
        }
        .sheet(isPresented: $incomingPodcastSubscription.isPresented, onDismiss: {
            incomingPodcastSubscription.dismiss()
        }) {
            IncomingPodcastSubscriptionView(controller: incomingPodcastSubscription)
                .presentationDetents([.medium, .large])
        }
        /*
        .safeAreaInset(edge: .top) {
            if shouldShowCloudSyncHint {
                cloudSyncHint
            }
        }
         */
        

    }

    @ViewBuilder
    private var cloudSyncHint: some View {
        HStack(spacing: 10) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Syncing from iCloud")
                    .font(.subheadline.weight(.semibold))
                Text("If this Apple ID already has podcast data, episodes and podcasts will appear here shortly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var compactPhoneLayout: some View {
        TabView(selection: $selectedTab) {
            Tab("Up next", systemImage: "calendar.day.timeline.leading", value: RootTab.playlist) {
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
            playerBar
        }
    }

    @ViewBuilder
    private var iPadSidebarLayout: some View {
        NavigationSplitView {
            List(selection: $selectedSidebarDestination) {
                Section("Listen") {
                    sidebarRow(for: .queue)
                    sidebarRow(for: .inbox, badge: inboxCount)
                }

                Section("Library") {
                    sidebarRow(for: .library)
                    sidebarRow(for: .downloads)
                    sidebarRow(for: .bookmarks)
                    sidebarRow(for: .history)
                }

                Section("Discover") {
                    sidebarRow(for: .search)
                }

                Section {
                    sidebarRow(for: .settings)
                }
            }
            .navigationTitle("Podcasts")
            .listStyle(.sidebar)
        } detail: {
            Group {
                if let selectedSidebarDestination {
                    sidebarDestinationView(for: selectedSidebarDestination)
                } else {
                    ContentUnavailableView("Select a Section", systemImage: "sidebar.left")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if Player.shared.currentEpisode != nil {
                    playerBar
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                }
            }
        }
    }

    @ViewBuilder
    private func sidebarRow(for destination: SidebarDestination, badge: Int? = nil) -> some View {
        NavigationLink(value: destination) {
            HStack(spacing: 10) {
                Label(destination.title, systemImage: destination.symbol)
                Spacer()
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red, in: Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private func sidebarDestinationView(for destination: SidebarDestination) -> some View {
        switch destination {
        case .queue:
            PlaylistView()
        case .inbox:
            InboxView()
        case .library:
            LibraryView()
        case .search:
            AddPodcastView(search: $search)
                .searchable(text: $search, prompt: "URL or Search")
        case .downloads:
            NavigationStack { DownloadedEpisodesView() }
        case .bookmarks:
            NavigationStack { BookmarkListView() }
        case .history:
            NavigationStack { PlaySessionDebugView() }
        case .settings:
            NavigationStack {
                PodcastSettingsView(podcast: nil, modelContainer: modelContext.container)
            }
        }
    }

    @ViewBuilder
    private var playerBar: some View {
        PlayerTabBarView()
            .opacity(Player.shared.currentEpisode == nil ? 0 : 1)
            .allowsHitTesting(Player.shared.currentEpisode != nil)
    }
    
    func setGoingToBackgroundDate() {
        goingToBackgroundDate = Date()
    }
    
    // MARK: - Manual count loader
    private func loadInboxCount() async {
        let predicate = #Predicate<Episode> { $0.metaData?.isInbox == true }
        // We only need the count. SwiftData doesn’t have COUNT(*) yet,
        // so fetch IDs only and count them to keep memory small.
        var descriptor = FetchDescriptor<Episode>(predicate: predicate)
        descriptor.propertiesToFetch = [\.id]
        do {
            let results = try modelContext.fetch(descriptor)
            await MainActor.run {
                inboxCount = results.count
            }
        } catch {
            // If fetch fails, keep current badge (or set to 0)
            await MainActor.run {
                inboxCount = 0
            }
        }
    }

    private func refreshCloudSyncExpectation() {
        expectedRemoteLibraryData = CloudSyncExpectationStore.hasExpectedRemoteData()
    }

    private func refreshCloudAccountStatus() async {
        let container = CKContainer(identifier: "iCloud.de.holgerkrupp.PodcastClient")
        do {
            let status = try await container.accountStatus()
            await MainActor.run {
                cloudAccountAvailable = (status == .available)
            }
        } catch {
            await MainActor.run {
                cloudAccountAvailable = false
            }
        }
    }
        
}

#Preview {
    ContentView()
        .modelContainer(for: Podcast.self, inMemory: true, isAutosaveEnabled: true)
}
