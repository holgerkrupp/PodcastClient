//
//  PodcastList.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import SwiftUI
import SwiftData



struct PodcastListView: View {
    
    @Environment(\.modelContext) var modelContext
    @Query var podcasts: [Podcast]

    
    
    var body: some View {
        List{
            ForEach(podcasts) { podcast in
                Text(podcast.title)
                
            }
            Text("Subscribe")
        }
    }
}

#Preview {
    PodcastListView()
}
