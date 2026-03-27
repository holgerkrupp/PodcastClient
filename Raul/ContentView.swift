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

    @AppStorage("goingToBackgroundDate") var goingToBackgroundDate: Date?
    @State private var inboxCount: Int = 0
    @State private var selectedTab: RootTab = .playlist
    
    @State private var search:String = ""
    @StateObject private var incomingPodcastSubscription = IncomingPodcastSubscriptionController()
    private var SETTINGgoingBackToPlayerafterBackground: Bool = true

    
    @AppStorage("lastPlayedEpisodeID") var lastPlayedEpisode:Int?
    
    var body: some View {
        
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
            }

            
        }
       // .searchable(text: $search, prompt: "URL or Search")
        .tabBarMinimizeBehavior(.onScrollDown)
        
        .tabViewBottomAccessory {
              PlayerTabBarView()
                .opacity(Player.shared.currentEpisode == nil ? 0 : 1)
                .allowsHitTesting(Player.shared.currentEpisode != nil)
            
 
        }

        
        .task {
            await loadInboxCount()
        }
        .onChange(of: phase, {
            if SETTINGgoingBackToPlayerafterBackground{
                switch phase {
                case .background:
                    setGoingToBackgroundDate()
                   
                case .active:
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
            Task { await loadInboxCount() }
        }
        .onOpenURL { url in
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
        
}

#Preview {
    ContentView()
        .modelContainer(for: Podcast.self, inMemory: true, isAutosaveEnabled: true)
}
