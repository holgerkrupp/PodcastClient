//
//  ITunesResultView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 04.02.24.
//

import SwiftUI

struct ITunesResultView: View {
    @State var iTunesResults:[ITunesFeed] = []
    
    var subscriptionManager = SubscriptionManager.shared
    
    var body: some View {
        
        
       
            ForEach(iTunesResults, id:\.self){ podcast in
                iTunesMiniView(podcast: podcast)
            }
        }
    
}

#Preview {
    ITunesResultView()
}


struct iTunesMiniView: View {
    @State var podcast: ITunesFeed
    var subscriptionManager = SubscriptionManager.shared
    @State var subscribed:Bool? = false
    
    
    var body: some View {
        HStack{
            if let image = podcast.artworkURL{
                ImageWithURL(image)
                    .scaledToFit()
                    .frame(width: 50, height: 50)
            }
            VStack(alignment: .leading){
                Text(podcast.title ?? "")
                if let artist = podcast.artist{
                    Text(artist)
                        .font(.caption)
                }
                if let date = podcast.lastRelease{
                    Text("Last Release: \(date.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if subscribed == nil{
                ProgressView()
            }else if subscribed == false{
                Button {
                    Task{
                        
                        if let url = podcast.url{
                            subscribed = nil
                            subscribed = await subscriptionManager.subscribe(to: url)
                        }
                    }
                } label: {
                    
                    Text("Subscribe")
                }
                .buttonStyle(.bordered)
            }else{
                Image(systemName: "checkmark")
            }

        }
    }
}
