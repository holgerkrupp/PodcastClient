//
//  EpisodeControlView.swift
//  Raul
//
//  Created by Holger Krupp on 07.04.25.
//


import SwiftUI

struct EpisodeControlView: View {


    @Bindable var episode: Episode
 //   @StateObject private var manager = DownloadManager.shared
    @Environment(\.modelContext) private var modelContext
    @State private var downloadProgress: Double = 0.0
    @State private var isDownloading: Bool = false
    
    var playlistViewModel: PlaylistViewModel? = {
        guard let container = ModelContainerManager().container else {
            print("Warning: Could not create PlaylistViewModel because ModelContainer is nil.")
            return nil
        }
        return PlaylistViewModel(container: container)
    }()
 


    var body: some View {

        HStack{
            Button(action: {
                Task{
                    await Player.shared.playEpisode(episode.id)
                }
            }) {
                Label("Play", systemImage: "play.fill")
                    .symbolRenderingMode(.hierarchical)
                    .scaledToFit()
                  
                    .foregroundColor(.accentColor)
                    .minimumScaleFactor(0.5)
                    .labelStyle(.iconOnly)
            }
           
                .buttonStyle(.plain)
            
           
          
            
            Spacer()
            if episode.playlist.isEmpty, episode.playlist.first?.playlist == nil {

            Button {
                Task{
                    await PlaylistViewModel(container: episode.modelContext?.container ?? modelContext.container).addEpisode(episode, to: .front)
                    
                }
            } label: {
                
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .symbolRenderingMode(.hierarchical)
                    .scaledToFit()
          
                    .foregroundColor(.accentColor)
                    .minimumScaleFactor(0.5)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
        
            
                Spacer()
            Button {
                Task{
                    await PlaylistViewModel(container: modelContext.container).addEpisode(episode, to: .end)
                }
            } label: {
                Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
                    .symbolRenderingMode(.hierarchical)
                    .scaledToFit()
                 
                    .foregroundColor(.accentColor)
                    .minimumScaleFactor(0.5)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
   
           
            }
            Spacer()
                Button {
                    Task{
                        await EpisodeActor(modelContainer: modelContext.container).archiveEpisode(episodeID: episode.id)
                    }
                } label: {
                    
                    Label( episode.metaData?.isArchived ?? false ? "Unarchive" : "Archive", systemImage: episode.metaData?.isArchived ?? false ? "archivebox.fill" : "archivebox")
                        .symbolRenderingMode(.hierarchical)
                        .scaledToFit()
                      
                        .foregroundColor(.accentColor)
                        .minimumScaleFactor(0.5)
                        .labelStyle(.automatic)
                }
                .buttonStyle(.plain)

            
            
        }

       

    }
}

