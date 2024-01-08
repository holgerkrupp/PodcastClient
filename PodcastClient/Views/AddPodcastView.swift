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
    
    
    var parserDelegate = PodcastParser()
    var subscriptionManager = SubscriptionManager.shared
    
    var feed:URL?{
        URL(string: newFeed.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    var body: some View {
        List{
            TextField(text: $newFeed) {
                Text("paste URL to feed")
            }.disabled(updateing)
            
            Button {
                updateing = true
                if let feed {
                    Task{
                        let finished = await subscriptionManager.subscribe(to: feed)
                        if finished == true{
                            newFeed = ""
                        }
                        updateing = false
                    }
                    
                }
                
            } label: {
                if updateing{
                    ProgressView()
                }else{
                    Text("Subscribe")
                }
                
            }
            .disabled(!newFeed.isValidURL || updateing)
            .buttonStyle(.bordered)
            
            
        }
    }
    
}

#Preview {
    AddPodcastView()
}
