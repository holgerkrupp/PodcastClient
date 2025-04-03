//
//  PodcastSearchView.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import SwiftUI
import fyyd_swift

struct PodcastSearchView: View {
    @StateObject private var viewModel = PodcastSearchViewModel()

    var body: some View {
        VStack {
            // Search bar
            TextField("Search for podcasts...", text: $viewModel.searchText)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding()

            if viewModel.isLoading {
                ProgressView()
            } else {
                List(viewModel.results, id: \.id) { podcast in
                    Text(podcast.title)
                }

                Text("Hot Podcasts")
                    .font(.headline)
                    .padding(.top)
                
                List(viewModel.hotPodcasts , id: \.id) { podcast in
                    Text(podcast.title)
                }
            }
        }
     

    }
}

#Preview {
    PodcastSearchView()
}
