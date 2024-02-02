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
    @State var selectedTab:Tab = Tab.episodes
    
    @State private var miniplayerHeight:CGFloat = 30.0
    var maxPlayerHeight:CGFloat = UIScreen.main.bounds.height - 150
    var minPlayerHeight:CGFloat = 30.0
    var body: some View {
        ZStack(alignment: .bottom){
            TabView(selection: $selectedTab){
             /*
                PlaylistView(modelContext: _modelContext)
                    .tag(Tab.upnext)
                    .tabItem {
                        Label("UpNext", systemImage: "play.square.stack")
                    }
                
                InboxView(modelContext: _modelContext)
                    .tag(Tab.episodes)
                    .tabItem {
                        Label("Inbox", systemImage: "tray.fill")
                    }
                
               */
                PodcastListView(modelContext: modelContext)
                    .tag(Tab.podcastlist)
                    .tabItem {
                        Label("Podcasts", systemImage: "list.bullet")
                        
                    }
                
                AddPodcastView(modelContext: _modelContext)
                    .tag(Tab.search)
                    .tabItem {
                        Label("Search", systemImage: "magnifyingglass")
                        
                    }
                
                
                SettingsView(modelContext: _modelContext)
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
            .clipShape(RoundedRectangle(cornerRadius: 10))
           /*
            if miniplayerHeight == maxPlayerHeight{
                Spacer()
                  //  .foregroundColor(.green)
                 //   .background(.ultraThinMaterial)
                    .frame(width: UIScreen.main.bounds.width, height: 50)
                    .onTapGesture {
                        withAnimation{
                            miniplayerHeight = 30.0
                        }
                    }
            }
            */

                
        }.ignoresSafeArea()
        if Player.shared.currentEpisode != nil{
            PlayerControlsView(miniPlayerHeight: $miniplayerHeight, maxPlayerHeight: maxPlayerHeight, minPlayerHeight: minPlayerHeight)
                .environment(Player.shared)
                .frame(height: miniplayerHeight)
        }

    }
        
}

