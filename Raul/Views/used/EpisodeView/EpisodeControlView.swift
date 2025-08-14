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
                    .padding(5)
                    // .foregroundColor(.accentColor)
                    .minimumScaleFactor(0.5)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
           
           
            
           
          
            
            Spacer()
            
            
                
            
            Button {
                Task{
                    await PlaylistViewModel(container: episode.modelContext?.container ?? modelContext.container).addEpisode(episode, to: .front)
                    
                }
            } label: {
                
                Label("Play Next", systemImage: (!episode.playlist.isEmpty || episode.playlist.first?.playlist != nil) ? "arrow.up.to.line" : "text.line.first.and.arrowtriangle.forward")
                    .symbolRenderingMode(.hierarchical)
                    .scaledToFit()
                    .padding(5)

                    // .foregroundColor(.accentColor)
                    .minimumScaleFactor(0.5)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
            
        
            
                Spacer()
            Button {
                Task{
                    await PlaylistViewModel(container: modelContext.container).addEpisode(episode, to: .end)
                }
            } label: {
                Label("Play Last", systemImage: (!episode.playlist.isEmpty || episode.playlist.first?.playlist != nil) ? "arrow.down.to.line" : "text.line.last.and.arrowtriangle.forward")
                    .symbolRenderingMode(.hierarchical)
                    .scaledToFit()
                    .padding(5)

                    // .foregroundColor(.accentColor)
                    .minimumScaleFactor(0.5)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
   
           
            
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

                       // .foregroundColor(.accentColor)
                        .minimumScaleFactor(0.5)
                        .labelStyle(.iconOnly)
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
