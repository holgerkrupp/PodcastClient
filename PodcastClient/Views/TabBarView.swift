//
//  TabView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import SwiftUI

struct TabBarView: View {
    
    @Environment(\.modelContext) var modelContext

    
    enum Tab: Int {
        case upnext, podcastlist, settings
    }
    @State var selectedTab = Tab.upnext
    
    
    var body: some View {
        TabView(selection: $selectedTab){
            
            Text("UpNext")
                .tag(Tab.upnext)
                .tabItem {
                    Label("UpNext", systemImage: "play.square.stack")
                    
                }
            
             PodcastList()
                .tag(Tab.podcastlist)
                .tabItem {
                    Label("UpNext", systemImage: "list.bullet")
                    
                }

        }
    }
}

#Preview {
    TabBarView()
}
