//
//  ListofEpisodesView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 08.01.24.
//

import SwiftUI

struct ListofEpisodesView: View {
    @Environment(\.modelContext) var modelContext

    @State  var episodes: [Episode]
    
    var body: some View {
        ForEach(episodes, id:\.self) { episode in
            
            EpisodeMiniView(model: EpisodeListItemModel(episode: episode))
                .modelContext(modelContext)
            
            
        }
    }
}
