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

    @AppStorage("goingToBackgroundDate") var goingToBackgroundDate: Date?
    @AppStorage(PlaylistPreferenceKeys.selectedPlaylistID) private var selectedPlaylistID: String = ""
    @State private var inboxCount: Int = 0
    @State private var selectedTab: RootTab = .playlist
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
    
    var body: some View {
        
        TabView(selection: $selectedTab) {
            
            Tab(LocalizedStringKey(playlistTabTitle), systemImage: "calendar.day.timeline.leading", value: RootTab.playlist) {
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
                selectedTab = .add
                incomingPodcastSubscription.handleIncomingURL(url)
                return
            }

            guard url.scheme == "upnext" else { return }
            selectedTab = .playlist
        }
        .sheet(isPresented: $incomingPodcastSubscription.isPresented, onDismiss: {
            incomingPodcastSubscription.dismiss()
        }) {
            IncomingPodcastSubscriptionView(controller: incomingPodcastSubscription)
                .presentationDetents([.medium, .large])
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
