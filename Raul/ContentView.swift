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

    @AppStorage("goingToBackgroundDate") var goingToBackgroundDate: Date?
    @Query(filter: #Predicate<Episode> { $0.metaData?.isInbox == true } ) var inBox: [Episode]
    
    private var SETTINGgoingBackToPlayerafterBackground: Bool = true
    
    enum Tab: Int {
        case player, podcasts, inbox, downloads, logger, settings, library
    }
    
    @State private var selectedTab: Tab = .player
   // @ObservedObject private var manager = DownloadManager.shared
    
    @AppStorage("lastPlayedEpisodeID") var lastPlayedEpisode:Int?
    
    var body: some View {
        TabView(selection: $selectedTab) {
            TimelineView()
                .tabItem {
                    Label("Player", systemImage: "play.circle.fill")
                }
                .tag(Tab.player)
           
                InboxView()
            
                .tabItem {
                    Label("Inbox", systemImage: "tray.fill")
                }
                .tag(Tab.inbox)
                .badge(inBox.count)
            
            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }
            .tag(Tab.library)

            

            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(Tab.settings)
            
            
#if DEBUG
            NavigationStack {
                LogView()
            }
                .tabItem {
                    Label("Log", systemImage: "text.bubble")
                }
                .tag(Tab.logger)
            
#endif // DEBUG


        }
#if iOS26
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            if Player.shared.currentEpisode != nil {
                PlayerTabBarView()
            }
        }
#endif // iOS26
        
        .onChange(of: phase, {
            if SETTINGgoingBackToPlayerafterBackground{
                switch phase {
                case .background:
                    setGoingToBackgroundDate()
                case .active:
                    if let goingToBackgroundDate = goingToBackgroundDate, goingToBackgroundDate < Date().addingTimeInterval(-5*60) {
                        selectedTab = .player
                    }
                    
                default: break
                }
            }
        })
        
  
    }
    
    func setGoingToBackgroundDate() {
        goingToBackgroundDate = Date()
    }
        
}

#Preview {
    ContentView()
        .modelContainer(for: Podcast.self, inMemory: true, isAutosaveEnabled: true)
}

