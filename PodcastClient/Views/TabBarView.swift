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
    @State var selectedTab = Tab.upnext
    
    @State private var miniplayerHeight:CGFloat = 20.0
    
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
                        miniplayerHeight = 20.0
                    }
                }


           
       
    
        PlayerControlsView(miniPlayerHeight: $miniplayerHeight)
            .environment(Player.shared)
        .frame(height: miniplayerHeight)
      
    }
}

/*
 #Preview {
 let schema = Schema([
 Item.self,
 Podcast.self,
 Episode.self,
 Chapter.self,
 Asset.self,
 PodcastSettings.self,
 Playlist.self
 
 ])
 let config = ModelConfiguration(isStoredInMemoryOnly: true)
 let container = try! ModelContainer(for: schema, configurations: config)
 
 TabBarView()
 .modelContainer(container)
 
 }
 */
