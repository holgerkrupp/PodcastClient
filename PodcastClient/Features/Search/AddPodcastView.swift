//
//  AddPodcastView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 08.12.23.
//

import SwiftUI

struct AddPodcastView: View {
    @Environment(\.modelContext) var modelContext

    @State var newFeed:String = "https://hierisauch.net/feed/test/"
    @State private var updateing = false
    @State private var iTunesResults:[ITunesFeed]?
    
    var parserDelegate = PodcastParser()
    var subscriptionManager = SubscriptionManager()
    
    var feed:URL?{
        URL(string: newFeed.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    var body: some View {
        List{
            Section {
                HStack{
                    TextField(text: $newFeed) {
                        Text("Search or enter URL")
                    }.disabled(updateing)
                 
                    
                    Button {
                        updateing = true
                        if let feed, newFeed.isValidURL {
                            Task{
                                let finished = await subscriptionManager.subscribe(to: feed)
                                if finished == true{
                                    newFeed = ""
                                }
                                updateing = false
                            }
                        }else{
                            Task{
                                iTunesResults = await iTunesSearchManager().search(for: newFeed)
                                updateing = false
                            }
                        }
                        
                    } label: {
                        if updateing{
                            ProgressView()
                        }else{
                            if (newFeed.isValidURL) {
                                Text("Subscribe")
                            }else{
                                Text("Search")
                            }
                        }
                        
                    }
                    .disabled(newFeed.isEmpty || updateing)
                    .buttonStyle(.bordered)
                }
            }

            
            
            if let iTunesResults{
                Section{
                    ITunesResultView(iTunesResults: iTunesResults)
                }
                
            }
            
            
        }
      
        
    }
    
}

#Preview {
    AddPodcastView()
}
