//
//  PodcastSearchView.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import SwiftUI
import fyyd_swift

struct HotPodcastView: View {
    @StateObject private var viewModel = PodcastSearchViewModel()
    @Environment(\.modelContext) private var context


    var body: some View {
        if !viewModel.languages.isEmpty {
            Picker("Language", selection: $viewModel.selectedLanguage) {
                ForEach(viewModel.languages, id: \.self) { name in
                    
                
                        Text(name.languageName()).tag(name)
                }
            }
            .pickerStyle(.menu)
            .padding()
        } else {
            ProgressView("Loading languages...") // Show loading indicator if needed
        }
        
        VStack {
            

            

            if viewModel.isLoading {
                ProgressView()
            } else {


                ForEach(viewModel.hotPodcasts , id: \.id) { podcast in
                    SubscribeToPodcastView(fyydPodcastFeed: podcast)
                        .modelContext(context)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0,
                                             leading: 0,
                                             bottom: 1,
                                             trailing: 0))
                    
                }
                .listStyle(.plain)
                .navigationTitle("Hot")
            }
        }
     

    }
}

#Preview {
    HotPodcastView()
}
