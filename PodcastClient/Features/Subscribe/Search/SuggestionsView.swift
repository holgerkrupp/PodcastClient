//
//  SuggestionsView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 18.02.24.
//

import SwiftUI

struct SuggestionsView: View {
   @State var languages:[String]?
    @State var language:String = Locale.current.language.languageCode?.identifier ?? "en"
    @State var searchResults:[PodcastFeed]?

    var body: some View {
        Section {
            Picker("Language", selection: $language) {
                ForEach(languages ?? [], id:\.self){ lang in
                    Text(lang)
                }
            }.onAppear{
                Task{
                    languages =  await FyydSearchManager().getLanguages()
                    searchResults = await FyydSearchManager().search(for: "hot", endpoint: .hot, lang: language)
                }
            }
            .onChange(of: language) {
                Task{
                    searchResults = nil
                    searchResults = await FyydSearchManager().search(for: "hot", endpoint: .hot, lang: language)
                }
            }
        } header: {
            Text("What others are listening")
        }

        
            

        
        ForEach(searchResults ?? [], id:\.self){ podcast in
            SubscribeToView(newPodcastFeed: podcast)
        }
    }

    
}

