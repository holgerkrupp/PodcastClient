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
                episode.playNow()
                
            } label: {
                if episode.isAvailableLocally {
                    Image(systemName: "play")
                        .resizable()
                        .scaledToFit()
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
                    Text("Delete")
                    
                    
                }
                .buttonStyle(.bordered)
            }else if episode.downloadStatus.isDownloading{
                ProgressView(value: episode.downloadStatus.downloadProgress)
                    .progressViewStyle(.linear)
                  
            }else{
                Button {
                    episode.download()
                } label: {
                    Image(systemName: "icloud.and.arrow.down")
                        .resizable()
                        .scaledToFit()
                    
                    
                }
                .buttonStyle(.bordered)
            }
            

        }
    }
}
