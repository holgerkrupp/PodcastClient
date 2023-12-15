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
        case upnext, podcastlist, settings
    }
    @State var selectedTab = Tab.upnext
    
    @State private var miniplayerHeight:CGFloat = 20.0
    
    var body: some View {

            VStack{
         
                TabView(selection: $selectedTab){
                    
                    PlaylistView()
                        .tag(Tab.upnext)
                        .tabItem {
                            Label("UpNext", systemImage: "play.square.stack")
                            
                        }
                    
                    PodcastListView(modelContext: modelContext)
                        .tag(Tab.podcastlist)
                        .tabItem {
                            Label("Podcasts", systemImage: "list.bullet")
                            
                        }
                    
                    
                    Text("Settings")
                        .tag(Tab.settings)
                        .tabItem {
                            Label("Settings", systemImage: "gear")
                            
                        }
                
            }
               
            }.offset(y:-miniplayerHeight)
           
       
    
        PlayerControlsView(miniplayerHeight: $miniplayerHeight)
        .frame(height: miniplayerHeight)
        .padding()
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
