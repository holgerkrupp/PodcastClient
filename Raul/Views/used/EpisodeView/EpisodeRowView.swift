//
//  EpisodeRowView.swift
//  Raul
//
//  Created by Holger Krupp on 12.04.25.
//
import SwiftUI
import SwiftData

struct EpisodeRowView: View {
    static func == (lhs: EpisodeRowView, rhs: EpisodeRowView) -> Bool {
        lhs.episode.id == rhs.episode.id &&
        lhs.episode.metaData?.lastPlayed == rhs.episode.metaData?.lastPlayed
    }
    @Environment(\.modelContext) private var modelContext
    @Environment(\.deviceUIStyle) var style
    @Environment(DownloadedFilesManager.self) var fileManager


    @State private var presentingModal : Bool = false
    var episode: Episode
    private let height:CGFloat = 210
  
    
    var body: some View {

            VStack(alignment: .center) {
                ZStack{
                    
                    
                        CoverImageView(podcast: episode.podcast)
                            .scaledToFill()
                            .frame(height: height)
                            .clipped()
                        
                       
                        
                    VStack(alignment: .leading){
  

                            HStack{
                                ZStack(alignment: .topTrailing) {
                                    CoverImageView(episode: episode)
                                        .frame(width: 120, height: 120)
                                        .cornerRadius(8)
                                    if episode.bookmarks?.isEmpty == false {
                                        Image(systemName: "bookmark.fill")
                                            .resizable()
                                            .frame(height: 50)
                                            .foregroundColor(.accent)
                                            .scaledToFit()
                                            
                                    }
                                }
                                VStack(alignment: .leading){
                                    HStack{
                                        Text(episode.podcast?.title ?? "")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                        Spacer()
                                        Text((episode.publishDate?.formatted(.relative(presentation: .named)) ?? ""))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Text(episode.title)
                                        .font(.headline)
                                        .lineLimit(3)
                                        .minimumScaleFactor(0.5)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    HStack {
                                        if let remainingTime = episode.remainingTime,remainingTime != episode.duration, remainingTime > 0 {
                                            Text(Duration.seconds(episode.remainingTime ?? 0.0).formatted(.units(width: .narrow)) + " remaining")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }else{
                                            Text(Duration.seconds(episode.duration ?? 0.0).formatted(.units(width: .narrow)))
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
   
                                        
                                        
                                    }
                                    
                                    HStack {
                                        
                                        if episode.metaData?.completionDate != nil {
                                            Image("custom.play.circle.badge.checkmark")
                                        } else {
                                            if fileManager.isDownloaded(episode.localFile) == true {
                                                Image(systemName: style.sfSymbolName)
                                            }else{
                                                Image(systemName: "cloud")
                                            }
                                        }
                                        
                                        if (episode.chapters?.count ?? 0)  > 0 {
                                            Image(systemName: "list.bullet")
                                        }
                                        if episode.externalFiles.contains(where: {$0.category == .transcript}) || episode.transcriptLines?.count ?? 0 > 0 {
                                            
                                            Image(systemName: "quote.bubble")
                                            
                                           
                                        }
                                        
                                     
                                        
                                            Spacer()
                                        
                               
                                      
                                         DownloadControllView(episode: episode, showDelete: false)
                                            .symbolRenderingMode(.hierarchical)
                                            .padding(8)
                                            .foregroundColor(.primary)
                                            .labelStyle(.iconOnly)

                                    }
                                    .frame(maxWidth: .infinity, maxHeight: 30)
                                    .buttonStyle(.plain)
                                 

                                }
                                .frame(height: 120)
                            }
                           
                        EpisodeControlView(episode: episode)
                            .modelContainer(modelContext.container)
                            .frame(height: 50)
                            .padding(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                

                           
                        }.padding()
                    
                    .background(
                        Rectangle()
                            .fill(.ultraThinMaterial)
                       
                    )
                     

                    
                   
                   
                
            }
                
                .frame(height: height)
                
                .overlay(alignment: .bottomLeading) {

                    
                    Rectangle()
                        .fill(Color.accent)
                      //  .frame(width: geo.size.width * (fakeProgress ?? player.progress))
                        .scaleEffect(x: max(0.0, min(1.0, episode.maxPlayProgress)), y: 1, anchor: .leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                    .frame(height: 4) // only care about height
                }
                 
            
        }
            
            .sheet(isPresented: $presentingModal, content: {
                EpisodeDetailView(episode: episode)
                  
            })
          
        

    }
    

}

#Preview {
    // Dummy Podcast
    let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
    podcast.title = "Sample Podcast"
    podcast.author = "Sample Author"
    podcast.desc = "A fun show about testing previews."

    // Dummy Episode
    let episode = Episode(
        id: UUID(),
        title: "Sample Episode Title",
        publishDate: Date(),
        url: URL(string: "https://example.com/episode.mp3")!,
        podcast: podcast,
        duration: 3600,
        author: "Episode Author"
    )
    episode.desc = "A very interesting episode about previews."
    episode.metaData?.playPosition = 900 // Simulate 15 mins listened
    episode.metaData?.maxPlayposition = 1200 // Simulate max progress
    episode.metaData?.lastPlayed = Date()

    // Inject a dummy DownloadedFilesManager for preview
    let tempFolder = FileManager.default.temporaryDirectory
    let previewFilesManager = DownloadedFilesManager(folder: tempFolder)

    return EpisodeRowView(episode: episode)
        .environment(previewFilesManager)
}


