//
//  EpisodeControlView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.01.24.
//

import SwiftUI

struct EpisodeControlView: View {
    @State var episode:Episode


    

    var body: some View {
        HStack{
            Button {
              //  episode.playNow()
               // Player.shared.currentEpisode = episode
            } label: {
                if episode.isAvailableLocally {
                    Label {
                        Text("Play now")
                    } icon: {
                        Image(systemName: "play")
                            .resizable()
                            .scaledToFit()
                    }
                    .labelStyle(.iconOnly)
                }else{
                    Text("Stream Now")
                }
            }
            .buttonStyle(.bordered)
            Spacer()
            
            if episode.isAvailableLocally{
                Button {
                    episode.removeFile()
                } label: {
                    Label {
                        Text("Delete")
                    } icon: {
                        Image(systemName: "trash")
                            .resizable()
                            .scaledToFit()
                    }
                    .labelStyle(.iconOnly)
                    
                    
                }
                .buttonStyle(.bordered)
            }else if episode.downloadStatus.isDownloading{
                ProgressView(value: episode.downloadStatus.downloadProgress)
                    .progressViewStyle(.linear)
                  
            }else{
                Button {
                    episode.download()
                } label: {
                    Label {
                        Text("Download")
                    } icon: {
                        Image(systemName: "icloud.and.arrow.down")
                            .resizable()
                            .scaledToFit()
                    }
                    .labelStyle(.iconOnly)
                    
                    
                }
                .buttonStyle(.bordered)
            }
            

        }
        .frame(maxWidth: .infinity, maxHeight: 40)
    }
}
