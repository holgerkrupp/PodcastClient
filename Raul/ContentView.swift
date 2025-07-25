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
    
    @State private var search:String = ""
    private var SETTINGgoingBackToPlayerafterBackground: Bool = true
    /*
    enum Tab: Int {
        case player, podcasts, inbox, downloads, logger, settings, library, timeline
    }
    
    @State private var selectedTab: Tab = .timeline
     */
   // @ObservedObject private var manager = DownloadManager.shared
    
    @AppStorage("lastPlayedEpisodeID") var lastPlayedEpisode:Int?
    
    var body: some View {
        
        TabView() {
            Tab {
                PlaylistView()
            } label: {
                Label("Up next", systemImage: "calendar.day.timeline.leading")
            }
            
            Tab {
                InboxView()
            } label: {
                Label("Inbox", systemImage: "tray.fill")
            }
            .badge(inBox.count)

            Tab {
                LibraryView()
            } label: {
                Label("Library", systemImage: "books.vertical")
            }
            
            
            Tab(role: .search) {
                AddPodcastView()
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }

            
        }
        .searchable(text: $search)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
           
                PlayerTabBarView()
                .opacity(Player.shared.currentEpisode == nil ? 0 : 1)
                .allowsHitTesting(Player.shared.currentEpisode != nil)
            
 
        }

        
        .onChange(of: phase, {
            if SETTINGgoingBackToPlayerafterBackground{
                switch phase {
                case .background:
                    setGoingToBackgroundDate()
                   
                case .active:
                    if let goingToBackgroundDate = goingToBackgroundDate, goingToBackgroundDate < Date().addingTimeInterval(-5*60) {
                       
                        //    selectedTab = .timeline
                       
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

