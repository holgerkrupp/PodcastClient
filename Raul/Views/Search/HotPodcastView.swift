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
        VStack {
            
            if !viewModel.languages.isEmpty {
                Picker("Language", selection: $viewModel.selectedLanguage) {
                    ForEach(viewModel.languages, id: \.self) { name in
                        
                    
                            Text(name.languageName()).tag(name)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .padding()
            } else {
                ProgressView("Loading languages...") // Show loading indicator if needed
            }
            

            if viewModel.isLoading {
                ProgressView()
            } else {

                Text("Hot Podcasts")
                    .font(.headline)
                    .padding(.top)
                
                List(viewModel.hotPodcasts , id: \.id) { podcast in
                    SubscribeToPodcastView(newPodcastFeed: podcast)
                        .modelContext(context)
                    
                }
            }
        }
     

    }
}

#Preview {
    HotPodcastView()
}
