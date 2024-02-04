//
//  ITunesResultView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 04.02.24.
//

import SwiftUI

struct ITunesResultView: View {
    @State var iTunesResults:[ITunesFeed] = []
    
    var subscriptionManager = SubscriptionManager()
    
    var body: some View {
       
            ForEach(iTunesResults, id:\.self){ podcast in
                HStack{
                    Text(podcast.title ?? "")
                    Button {
                        Task{
                            if let url = podcast.url{
                                await subscriptionManager.subscribe(to: url)
                            }
                        }
                    } label: {
                        Text("Subscribe")
                    }
                }
            }
        }
    
}

#Preview {
    ITunesResultView()
}
