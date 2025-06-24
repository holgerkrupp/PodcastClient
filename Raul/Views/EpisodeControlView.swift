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
                    .padding(8)
                    .foregroundColor(.accentColor)
                    .minimumScaleFactor(0.5)
                    .labelStyle(.iconOnly)
            }
           
                .buttonStyle(.plain)
            
           
            .frame(width: 100, height: 50)
            
            Spacer()
            if episode.playlist.isEmpty, episode.playlist.first?.playlist == nil {
       //     if !PlaylistViewModel(container: episode.modelContext?.container ?? modelContext.container).entries.contains(where: { $0.episode?.id == episode.id }) {
                    
           
            
            Button {
                Task{
                    await PlaylistViewModel(container: episode.modelContext?.container ?? modelContext.container).addEpisode(episode, to: .front)
                    
                }
            } label: {
                
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .symbolRenderingMode(.hierarchical)
                    .scaledToFit()
                    .padding(8)
                    .foregroundColor(.accentColor)
                    .minimumScaleFactor(0.5)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .frame(width: 50, height: 50)
            
                Spacer()
            Button {
                Task{
                    await PlaylistViewModel(container: modelContext.container).addEpisode(episode, to: .end)
                }
            } label: {
                Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
                    .symbolRenderingMode(.hierarchical)
                    .scaledToFit()
                    .padding(8)
                    .foregroundColor(.accentColor)
                    .minimumScaleFactor(0.5)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .frame(width: 50, height: 50)
           
            }
            
            
            Spacer()
            
            
                
                Menu {
                    DownloadControllView(episode: episode)
                    Divider()
                    if episode.metaData?.status != .history {
                        Button {
                            Task{
                                await EpisodeActor(modelContainer: modelContext.container).moveToHistory(episodeID: episode.id)
                            }
                        } label: {
                            
                            Label("Move to History" , image: "custom.play.circle.badge.checkmark")
                                .symbolRenderingMode(.hierarchical)
                                .scaledToFit()
                                .padding(8)
                                .foregroundColor(.accentColor)
                                .minimumScaleFactor(0.5)
                                .labelStyle(.automatic)
                        }
                       
                    }
                        
                    
                    Button {
                        Task{
                            await EpisodeActor(modelContainer: modelContext.container).archiveEpisode(episodeID: episode.id)
                        }
                    } label: {
                        
                        Label( episode.metaData?.isArchived ?? false ? "Unarchive" : "Archive", systemImage: episode.metaData?.isArchived ?? false ? "archivebox.fill" : "archivebox")
                            .symbolRenderingMode(.hierarchical)
                            .scaledToFit()
                            .padding(8)
                            .foregroundColor(.accentColor)
                            .minimumScaleFactor(0.5)
                            .labelStyle(.automatic)
                    }
                    
                } label: {
                    ZStack{
                        Capsule()
                            .fill(.clear)
                        
                        Label("Action", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                        
                    }
                    .frame(width: 100, height: 50)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)

                
            
            /*
            Button {
                Task{
                    await EpisodeActor(modelContainer: modelContext.container).archiveEpisode(episodeID: episode.id)
                }
            } label: {
                
                Label("Archive", systemImage: episode.metaData?.isArchived ?? false ? "archivebox.fill" : "archivebox")
                    .symbolRenderingMode(.hierarchical)
                    .scaledToFit()
                    .padding(8)
                    .foregroundColor(.accentColor)
                    .minimumScaleFactor(0.5)
                    .labelStyle(.automatic)
            }
            .buttonStyle(.plain)
            .background(.ultraThickMaterial, in: Capsule())
            .frame(width: 100, height: 50)
            .shadow(radius: 5)
            */
         
                
                

            
            
        }

       

    }
}

