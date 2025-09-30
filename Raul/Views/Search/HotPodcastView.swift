//
//  PodcastSearchView.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import SwiftUI
import fyyd_swift

struct HotPodcastView: View {
    @ObservedObject  var viewModel : PodcastSearchViewModel
    @Environment(\.modelContext) private var context
    
    
    var body: some View {
        
        
        
        
        
        
     
            if viewModel.isLoading {
                ProgressView()
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
                
                .listStyle(.plain)
                .navigationTitle("Hot")
                
                
            }
            
            
        

    }
}


