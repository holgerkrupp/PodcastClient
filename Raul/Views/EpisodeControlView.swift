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
    
    var playlistViewModel:PlaylistViewModel = PlaylistViewModel(container: ModelContainerManager().container)
 


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
                    .padding(12)
                    .foregroundColor(.accentColor)
                    .minimumScaleFactor(0.5)
                    .labelStyle(.automatic)
            }
            .buttonStyle(.plain)
            .background(.thickMaterial, in: Capsule())
            .frame(width: 100, height: 50)
            .shadow(radius: 5)
            Spacer()
            
            Button {
                Task{
                    await playlistViewModel.addEpisode(episode, to: .front)
                    
                }
            } label: {
                
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .symbolRenderingMode(.hierarchical)
                    .scaledToFit()
                    .padding(12)
                    .foregroundColor(.accentColor)
                    .minimumScaleFactor(0.5)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .background(.thickMaterial, in: Capsule())
            .frame(width: 50, height: 50)
            .shadow(radius: 5)
            
            
            Button {
                Task{
                    await playlistViewModel.addEpisode(episode, to: .end)
                }
            } label: {
                Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
                    .symbolRenderingMode(.hierarchical)
                    .scaledToFit()
                    .padding(12)
                    .foregroundColor(.accentColor)
                    .minimumScaleFactor(0.5)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .background(.thickMaterial, in: Capsule())
            .frame(width: 50, height: 50)
            .shadow(radius: 5)
           
            
            
            
            Spacer()
            
            Button {
                Task{
                    await EpisodeActor(modelContainer: modelContext.container).archiveEpisode(episodeID: episode.id)
                }
            } label: {
                
                Label("Archive", systemImage: episode.metaData?.isArchived ?? false ? "archivebox.fill" : "archivebox")
                    .symbolRenderingMode(.hierarchical)
                    .scaledToFit()
                    .padding(12)
                    .foregroundColor(.accentColor)
                    .minimumScaleFactor(0.5)
                    .labelStyle(.automatic)
            }
            .buttonStyle(.plain)
            .background(.ultraThickMaterial, in: Capsule())
            .frame(width: 100, height: 50)
            .shadow(radius: 5)
         
                
                

            
            
        }

    }
}

#Preview {
    let URL = URL(string: "http:s//holgerkrupp.de")!
    let podcast = Podcast(feed: URL)
    let episode = Episode(id: UUID(), title: "Test Episode", url: URL, podcast: podcast)
    EpisodeControlView(episode: episode)
}
