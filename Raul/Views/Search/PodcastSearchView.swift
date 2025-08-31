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
                                         bottom: 0,
                                         trailing: 0))
                
                
          
          //  THIS WOULD BE FOR A COMBINED SEARCH of Fyyd and iTunes
           
           } else if !viewModel.searchResults.isEmpty{
                
                ForEach(viewModel.searchResults, id: \.self) { podcast in
                    SubscribeToPodcastView(newPodcastFeed: podcast)
                        .modelContext(context)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0,
                                             leading: 0,
                                             bottom: 0,
                                             trailing: 0))
                     //   .overlay(Text(podcast.url?.absoluteString ?? "--"), alignment: .bottom)
                     //   .overlay(Text(podcast.source?.description ?? "-"), alignment: Alignment(horizontal: .trailing, vertical: .top))
                }
                
                .navigationTitle("Subscribe")
           
                
            } else if !viewModel.results.isEmpty{
                
                ForEach(viewModel.results, id: \.self) { podcast in
                    SubscribeToPodcastView(newPodcastFeed: podcast)
                        .modelContext(context)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0,
                                             leading: 0,
                                             bottom: 0,
                                             trailing: 0))
                }
                
                .navigationTitle("Subscribe")
                
            }else if !viewModel.searchText.isEmpty{
                Text("no results for \(search)")
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }else{
                HotPodcastView(viewModel: viewModel)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0,
                                         leading: 0,
                                         bottom: 0,
                                         trailing: 0))
            }
            if let url = URL(string: "https://fyyd.de"){
                Link(destination: url) {
                    Label("Search is powered by fyyd", systemImage: "safari")
                    
                }
                .padding()
                .buttonStyle(.glass)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        
        EmptyView()
        .onChange(of: search) {
            viewModel.searchText = search
            
        }
        .toolbar {
            
            
            ToolbarItem(placement: .navigationBarTrailing) {
                if !viewModel.languages.isEmpty {
                Picker("Language", selection: $viewModel.selectedLanguage) {
                    ForEach(viewModel.languages, id: \.self) { name in
                        Text(name.languageName()).tag(name)
                    }
                }
                .pickerStyle(.menu)
                } else {
                    ProgressView("Loading languages...")
                }
            }
        }
     

    }
}

#Preview {
    @Previewable @State var search: String = ""
    PodcastSearchView(search: $search)
}
