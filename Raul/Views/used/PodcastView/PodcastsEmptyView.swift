//
//  InboxEmptyView.swift
//  Raul
//
//  Created by Holger Krupp on 18.05.25.
//

import SwiftUI

struct PodcastsEmptyView: View {
    @State var search: String = ""
    var body: some View {
        VStack{
            Text("Your Library is empty")
                .font(.headline)
            Divider()
            Text("You have not subscribed to any podcasts yet.")
            
          
               
                NavigationLink{
                    AddPodcastView(search: $search)
                } label: {
                    HStack{
                        Image(systemName: "plus.circle")
                        Text("Tap add Podcast to subscribe to some podcasts.")
                        
                    }
                    
                    .foregroundStyle(.accent)
                    .underline()
                }
            
            Text("You can import a OPML File, search the directory or browse for trending podcasts in different languages.")

        }
        .padding()
    }
}


