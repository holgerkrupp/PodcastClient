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
        case player, podcasts, inbox, downloads, logger, settings, library, timeline
    }
    
    @State private var selectedTab: Tab = .timeline
   // @ObservedObject private var manager = DownloadManager.shared
    
    @AppStorage("lastPlayedEpisodeID") var lastPlayedEpisode:Int?
    
    var body: some View {
        TabView(selection: $selectedTab) {
            PlaylistView()
                .tabItem {
                    Label("Up next", systemImage: "calendar.day.timeline.leading")
                }
                .tag(Tab.timeline)
          
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

        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            
            //if Player.shared.currentEpisode != nil {
                PlayerTabBarView()
           // }
        }

        
        .onChange(of: phase, {
            if SETTINGgoingBackToPlayerafterBackground{
                switch phase {
                case .background:
                    setGoingToBackgroundDate()
                case .active:
                    if let goingToBackgroundDate = goingToBackgroundDate, goingToBackgroundDate < Date().addingTimeInterval(-5*60) {
                        selectedTab = .timeline
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

