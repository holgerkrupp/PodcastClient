//
//  PodcastView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 06.12.23.
//

import SwiftUI

struct EpisodeView: View {
    
    @Environment(\.modelContext) var modelContext
    @State var episode:Episode
    
    var body: some View {
        List{
            Section {
                Text(episode.title ?? "")
                Text(episode.desc ?? "")
                    
                    }

            }
       
    }
}
/*
#Preview {
    PodcastView()
}
*/
