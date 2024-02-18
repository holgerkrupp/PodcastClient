//
//  TabView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import SwiftUI
import SwiftData

struct TabBarView: View {
    
    @Environment(\.modelContext) var modelContext

    
    enum Tab: Int {
        case upnext, episodes, podcastlist, search, settings, none
    }
    @AppStorage("selectedTab") var selectedTab:Tab = Tab.search
    
    
    @State private var miniplayerHeight:CGFloat = 30.0
    var maxPlayerHeight:CGFloat = UIScreen.main.bounds.height - 120
    var minPlayerHeight:CGFloat = 30.0

    var percent:Double {
        max(0.2, 1.0 - ((miniplayerHeight - minPlayerHeight)/(maxPlayerHeight - minPlayerHeight)))
    }
    
    var body: some View {
        ZStack(alignment: .bottom){

            TabView(selection: $selectedTab){
             
            
                PlaylistView()
                    .modelContext(modelContext)
                    .tag(Tab.upnext)
                    .tabItem {
                        Label("UpNext", systemImage: "play.square.stack")
                    }
                
                InboxView()
                    .modelContext(modelContext)
                    .tag(Tab.episodes)
                    .tabItem {
                        Label("Inbox", systemImage: "tray.fill")
                    }
                
               
                LibraryView()
                    .modelContext(modelContext)
                    .tag(Tab.podcastlist)
                    .tabItem {
                        Label("Podcasts", systemImage: "list.bullet")
                        
                    }
                
                AddPodcastView()
                    .modelContext(modelContext)
                    .tag(Tab.search)
                    .tabItem {
                        Label("Search", systemImage: "magnifyingglass")
                        
                    }
                
                
                SettingsView()
                    .modelContext(modelContext)
                    .tag(Tab.settings)
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                        
                    }
                
                
            }
          
            .onChange(of: selectedTab) {
                if selectedTab != .none{
                    withAnimation{
                        miniplayerHeight = 30.0
                    }
                }

            }
            .onChange(of: miniplayerHeight){
                if selectedTab != .none{
                    selectedTab = .none
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 30))
            .opacity(percent)
            .shadow(color: .black, radius: 5)


                
        }
        .ignoresSafeArea()
        
        if Player.shared.currentEpisode != nil{
            PlayerControlsView(miniPlayerHeight: $miniplayerHeight, maxPlayerHeight: maxPlayerHeight, minPlayerHeight: minPlayerHeight)
                .frame(height: miniplayerHeight)
                
              

        }

    }
        
}

