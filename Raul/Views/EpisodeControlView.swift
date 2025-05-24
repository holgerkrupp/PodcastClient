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
    
    var playlistViewModel:PlaylistViewModel = PlaylistViewModel(container: ModelContainerManager().container)
 


    var body: some View {
        HStack {
            
            if episode.metaData?.completionDate != nil {
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
                
                Image(systemName: "quote.bubble")
                
               
            }
            
         
            
                Spacer()
            
   
            
            if episode.metaData?.isAvailableLocally != true {
                DownloadControllView(episode: episode)
            }
            

        }
        .frame(maxWidth: .infinity, maxHeight: 30)
        HStack{
            Button(action: {
                Task{
                    await Player.shared.playEpisode(episode.id)
                }
            }) {
                Image(systemName: "play.fill")
                    .symbolRenderingMode(.hierarchical)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .foregroundColor(.background)
                    .background(
                        Circle()
                            .fill(.accent)
                    )
                
                
                
            }
            .buttonStyle(.plain)
            .frame(width: 50, height: 50)
            
            Spacer()
            
            Button {
                Task{
                    await playlistViewModel.addEpisode(episode, to: .front)
                    
                }
            } label: {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .symbolRenderingMode(.hierarchical)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .foregroundColor(.background)
                    .background(
                        Circle()
                            .fill(.accent)
                    )
                
                
                
            }
            .buttonStyle(.plain)
            .frame(width: 50, height: 50)
            
            
            Button {
                Task{
                    await playlistViewModel.addEpisode(episode, to: .end)
                }
            } label: {
                Image(systemName: "text.line.last.and.arrowtriangle.forward")
                    .symbolRenderingMode(.hierarchical)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .foregroundColor(.background)
                    .background(
                        Circle()
                            .fill(.accent)
                    )
                
                
                
            }
            .buttonStyle(.plain)
            .frame(width: 50, height: 50)
            
            Spacer()
            
            Button {
                Task{
                    await EpisodeActor(modelContainer: modelContext.container).archiveEpisode(episodeID: episode.id)
                }
            } label: {
                Image(systemName: episode.metaData?.isArchived ?? false ? "archivebox.fill" : "archivebox")
                    .symbolRenderingMode(.hierarchical)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .foregroundColor(.background)
                    .background(
                        Circle()
                            .fill(.accent)
                    )
                
                
                
            }
            .buttonStyle(.plain)
            .frame(width: 50, height: 50)
            
            
        }

    }
}

