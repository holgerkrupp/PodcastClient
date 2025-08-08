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
    @Environment(\.modelContext) private var context
    @Binding var search: String
    var body: some View {
        VStack {

            if viewModel.isLoading {
                ProgressView()
            }
            
            
            else if let singlePodcast = viewModel.singlePodcast{
                SubscribeToPodcastView(newPodcastFeed: singlePodcast)
                    .modelContext(context)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0,
                                         leading: 0,
                                         bottom: 1,
                                         trailing: 0))
                
            } else if !viewModel.results.isEmpty{
              
                ForEach(viewModel.results, id: \.id) { podcast in
                    SubscribeToPodcastView(fyydPodcastFeed: podcast)
                        .modelContext(context)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0,
                                             leading: 0,
                                             bottom: 1,
                                             trailing: 0))
                }
                
                .navigationTitle("Subscribe")

           
                
            }else{
                HotPodcastView()
               
            }
        }
        .onChange(of: search) {
            viewModel.searchText = search
        }
     

    }
}

#Preview {
    @Previewable @State var search: String = ""
    PodcastSearchView(search: $search)
}
