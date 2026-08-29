//
//  PodcastSearchView.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import SwiftUI

struct HotPodcastView: View {

    @Environment(\.modelContext) private var context
    @StateObject private var viewModel = PodcastSearchViewModel()

    var body: some View {
        List{
        Group{
            Picker("Region", selection: $viewModel.selectedRegion) {
                ForEach(viewModel.regions) { region in
                    Text(region.displayName).tag(region.code as String?)
                }
            }
            .pickerStyle(.menu)
        }
        .padding()
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(.init(top: 0,
                             leading: 0,
                             bottom: 0,
                             trailing: 0))
        
        
        
        
     
            if viewModel.isLoading {
                ProgressView()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0,
                                         leading: 0,
                                         bottom: 0,
                                         trailing: 0))
            } else {
                
               
                    ForEach(viewModel.hotPodcasts , id: \.self) { podcast in
                        SubscribeToPodcastView(newPodcastFeed: podcast)
                            .modelContext(context)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0,
                                                 leading: 0,
                                                 bottom: 0,
                                                 trailing: 0))
                        
                        
                    }
                }

                
                
            }
        .listStyle(.plain)
        .navigationTitle("Hot Podcasts")
            
            
        

    }
}


