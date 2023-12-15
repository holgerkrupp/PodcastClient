//
//  PodcastView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 06.12.23.
//

import SwiftUI
import SwiftData

struct EpisodeView: View {
    
    @Environment(\.modelContext) var modelContext
    @State var episode:Episode
    
    var body: some View {
        List{
            Section {
                VStack{
                    HStack{
                        if let imageULR = episode.image{
                            ImageWithURL(imageULR)
                                .scaledToFit()
                                .frame(width: 200, height: 200)
                        }else{
                            Image(systemName: "mic.fill")
                                .scaledToFit()
                                .frame(width: 200, height: 200)
                        }
                        VStack{
                            Text(episode.title ?? "")
                            Text(episode.subtitle ?? "")
                        }
                    }
                    Button {
                        Player.shared.currentEpisode = episode
                        Player.shared.playPause()
                    } label: {
                        Text("Play Now")
                    }

                }
                
                    
                    }

            }
        .listStyle(.plain)
       
    }
}

struct EpisodeMiniView: View {
    

    var episode:Episode
    
    var body: some View {
        HStack{
            if let imageULR = episode.image{
                ImageWithURL(imageULR)
                    .scaledToFit()
                    .frame(width: 50, height: 50)

            }else{
                Image(systemName: "mic.fill")
                    .scaledToFit()
                    .frame(width: 50, height: 50)
            }
            VStack{
                Text(episode.title ?? "")
            }
        }
    }

}
