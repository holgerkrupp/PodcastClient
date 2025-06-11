//
//  LibraryView.swift
//  Raul
//
//  Created by Holger Krupp on 29.05.25.
//

import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var context

    enum Selection {
        case podcasts, episodes
    }
    @State private var listSelection:Selection = .podcasts
    
    var body: some View {
        VStack {
            
            
            Picker(selection: $listSelection) {
                Text("Podcasts").tag(Selection.podcasts)
                Text("Episodes").tag(Selection.episodes)
            } label: {
                Text("Show")
            }
            .pickerStyle(.segmented)
            switch listSelection {
            case .podcasts:
                PodcastListView(modelContainer: context.container)
            case .episodes:
                AllEpisodesListView()
            }
        }
    }
}

#Preview {
    LibraryView()
}
