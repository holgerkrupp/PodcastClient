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
        case upnext, podcastlist, search, settings
    }
    @State var selectedTab:Tab = Tab.upnext
    
    @State private var miniplayerHeight:CGFloat = 30.0
    
    var body: some View {

        TabView(selection: $selectedTab){
            
            EpisodeListView(modelContext: modelContext)
                .tag(Tab.upnext)
                .tabItem {
                    Label("UpNext", systemImage: "play.square.stack")
                }

                    
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
                    withAnimation{
                        miniplayerHeight = 30.0
                    }
                }

        if Player.shared.currentEpisode != nil{
            PlayerControlsView(miniPlayerHeight: $miniplayerHeight)
                .environment(Player.shared)
                .frame(height: miniplayerHeight)
        }

        
       
      
    }
}

