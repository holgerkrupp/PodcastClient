//
//  PodcastView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 06.12.23.
//

import SwiftUI

struct PodcastView: View {
    
    @Environment(\.modelContext) var modelContext
    @State var podcast:Podcast
    
    var body: some View {
        List{
            Section {
                Text(podcast.title)
                Text(podcast.desc ?? "")
                    
                    }
            Section{
                ForEach(podcast.episodes ?? []){ episode in
                    Text(episode.title ?? "")
                }
            }
            }
        .onAppear(){
            dump(podcast)
        
        }
    }
}
/*
#Preview {
    PodcastView()
}
*/
