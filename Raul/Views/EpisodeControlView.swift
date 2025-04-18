//
//  EpisodeControlView.swift
//  Raul
//
//  Created by Holger Krupp on 07.04.25.
//


import SwiftUI

struct EpisodeControlView: View {
    @State var episode: Episode
 //   @StateObject private var manager = DownloadManager.shared
    @Environment(\.modelContext) private var modelContext
    @State private var downloadProgress: Double = 0.0
    @State private var isDownloading: Bool = false

    var body: some View {
        HStack {
            
            if episode.chapters.count > 0 {
                Image(systemName: "list.bullet")
            }
            if episode.transcripts.count > 0 {
                
                    Image(systemName: "text.quote")
                
               
            }
            
         
            
                Spacer()
            
   
            
            if episode.metaData?.isAvailableLocally == true {
                Button {
                    episode.deleteFile()
                } label: {
                    Image(systemName: "trash")
                        .resizable()
                        .scaledToFit()
                }
                .buttonStyle(.bordered)
            }
            
            DownloadControllView(episode: episode)

        }
        .frame(maxWidth: .infinity, maxHeight: 30)

    }
}

