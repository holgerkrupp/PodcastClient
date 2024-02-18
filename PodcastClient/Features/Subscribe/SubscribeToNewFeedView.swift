//
//  SubscribeToNewFeedView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 17.02.24.
//

import SwiftUI

struct SubscribeToView: View{
    
    var newPodcastFeed: PodcastFeed
    var formatStyle = Date.RelativeFormatStyle()

    @State private var subscribing = false
    
    var body: some View{
        VStack{
            Text(newPodcastFeed.title ?? "").font(.title3)

            
            HStack{
                if let image = newPodcastFeed.artworkURL{
                    ImageWithURL(image)
                        .scaledToFit()
                        .frame(width: 50, height: 50)
                }
                
                VStack(alignment: .leading){
                    if let artist = newPodcastFeed.artist{
                        Text(artist)
                            .font(.caption)
                    }
                    if let date = newPodcastFeed.lastRelease{
                        Text("Last Release: \(date.formatted(formatStyle))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                }
                Spacer()
                if newPodcastFeed.existing == false{
                    if newPodcastFeed.added == true{
                        Image(systemName: "checkmark.circle")
                    }else{
                        if newPodcastFeed.subscribing == true{
                            ProgressView()
                        }else{
                            Button {
                                
                                Task{
                                    await newPodcastFeed.subscribe()
                                }
                            } label: {
                                
                                Text("Subscribe")
                            }
                            .buttonStyle(.bordered)
                        }
                        if newPodcastFeed.status != nil {
                            Text(newPodcastFeed.status?.statusCode?.formatted() ?? "")
                        }
                    }
                }
            }
            Text(newPodcastFeed.url?.absoluteString ?? "").font(.caption)
            if let desc = newPodcastFeed.description{
                Text(desc)
                    .font(.body)
                    .padding()
            }

        }
    }
}
