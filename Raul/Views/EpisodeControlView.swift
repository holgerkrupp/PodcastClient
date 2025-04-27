//
//  EpisodeControlView.swift
//  Raul
//
//  Created by Holger Krupp on 07.04.25.
//


import SwiftUI

struct EpisodeControlView: View {
    @Environment(\.deviceUIStyle) var style

    @State var episode: Episode
 //   @StateObject private var manager = DownloadManager.shared
    @Environment(\.modelContext) private var modelContext
    @State private var downloadProgress: Double = 0.0
    @State private var isDownloading: Bool = false

    var body: some View {
        HStack {
            
            if episode.metaData?.finishedPlaying == true {
                Image("custom.play.circle.badge.checkmark")
            } else {
                if episode.metaData?.isAvailableLocally == true {
                    Image(systemName: style.sfSymbolName)
                }else{
                    Image(systemName: "cloud")
                }
            }
            
            if episode.chapters.count > 0 {
                Image(systemName: "list.bullet")
            }
            if episode.transcripts.count > 0 {
                
                    Image(systemName: "text.quote")
                
               
            }
            
         
            
                Spacer()
            
   
            
            if episode.metaData?.isAvailableLocally != true {
                DownloadControllView(episode: episode)
            }
            

        }
        .frame(maxWidth: .infinity, maxHeight: 30)

    }
}

