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
    

    var body: some View {

        HStack {
            Button(action: {
                Task{
                    await Player.shared.playEpisode(episode.id)
                }
            }) {
                Label("Play", systemImage: "play.fill")
                    .symbolRenderingMode(.hierarchical)
                    .scaledToFit()
                    .padding(5)
                    // .foregroundColor(.accent)
                    .minimumScaleFactor(0.5)
                    .labelStyle(.iconOnly)
                    .clipShape(Circle())
                    .frame(width: 50)
            }
            .buttonStyle(.glass)
            
            Spacer()
            
            GlassEffectContainer(spacing: 20.0) {
                HStack(spacing: 0.0) {
                    
                    Button {
                        Task{
                            await PlaylistViewModel(container: episode.modelContext?.container ?? modelContext.container).addEpisode(episode, to: .front)
                            
                        }
                    } label: {
                        
                        Label("Play Next", systemImage: (!(episode.playlist?.isEmpty ?? true) || episode.playlist?.first?.playlist != nil) ? "arrow.up.to.line" : "text.line.first.and.arrowtriangle.forward")
                            .symbolRenderingMode(.hierarchical)
                            .scaledToFit()
                            .padding(5)
                            .minimumScaleFactor(0.5)
                            .labelStyle(.iconOnly)
                            .frame(width: 50)
                           
                    }
                    .buttonStyle(.glass)
                    .clipShape(Circle())
                    
                 
                    Button {
                        Task{
                            await PlaylistViewModel(container: modelContext.container).addEpisode(episode, to: .end)
                        }
                    } label: {
                        Label("Play Last", systemImage: (!(episode.playlist?.isEmpty ?? true) || episode.playlist?.first?.playlist != nil) ? "arrow.down.to.line" : "text.line.last.and.arrowtriangle.forward")
                            .symbolRenderingMode(.hierarchical)
                            .scaledToFit()
                            .padding(5)
                            .minimumScaleFactor(0.5)
                            .labelStyle(.iconOnly)
                            .frame(width: 50)
                    }
                    .buttonStyle(.glass)
                    .clipShape(Circle())
                    
                }
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
                    .padding(5)

                   // .foregroundColor(.accent)
                    .minimumScaleFactor(0.5)
                    .labelStyle(.iconOnly)
                    .clipShape(Circle())
                    .frame(width: 50)
            }
            .buttonStyle(.glass)

            
            
        }
        

       

    }
}

#Preview {
    // Dummy Podcast
    let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
    podcast.title = "Sample Podcast"
    podcast.author = "Sample Author"

    // Dummy Episode
    let episode = Episode(
        id: UUID(),
        title: "Preview Test Episode",
        publishDate: Date(),
        url: URL(string: "https://example.com/ep.mp3")!,
        podcast: podcast,
        duration: 1234,
        author: "Preview Author"
    )
    episode.desc = "A previewable episode for testing controls."
    episode.metaData?.isArchived = false

    return EpisodeControlView(episode: episode)
}

