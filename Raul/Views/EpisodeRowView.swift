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


    
    @State var episode: Episode
    @State private var isExtended: Bool = false
    @State private var image: Image?
    
    var body: some View {

            VStack(alignment: .leading) {
                ZStack{
                    GeometryReader { geometry in
                        // Background layer
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.accentColor.opacity(0.5))
                            .frame(width: geometry.size.width * episode.playProgress)
                    }
                    .padding()
                    
                    
                    VStack{
                        
                        HStack {
                            Text("DEBUG")
                            Image(systemName: episode.metaData?.isArchived ?? false ? "archivebox.fill" : "archivebox")
                            Image(systemName: episode.metaData?.isInbox ?? false ? "tray.fill" : "tray")
                            Image(systemName: episode.metaData?.isHistory ?? false ? "newspaper.fill" : "newspaper")
                            
                            Image(systemName: episode.metaData?.isAvailableLocally ?? false ? "document.fill" : "document")
                                .foregroundColor(episode.metaData?.calculatedIsAvailableLocally ?? false == episode.metaData?.isAvailableLocally ?? false ? .primary : .red)
                           // Image(systemName: episode.metaData?.calculatedIsAvailableLocally ?? false ? "document.viewfinder.fill" : "document.viewfinder")
                            //    .foregroundColor(episode.metaData?.calculatedIsAvailableLocally ?? false == episode.metaData?.isAvailableLocally ?? false ? .primary : .red)
                            
                            Image(systemName: fileManager.isDownloaded(episode.localFile) ?? false ? "document.viewfinder.fill" : "document.viewfinder")
                                .foregroundColor(fileManager.isDownloaded(episode.localFile?.absoluteString ?? "") == episode.metaData?.isAvailableLocally ?? false ? .primary : .red)
                            
                            
                            
                            if episode.downloadItem?.isDownloading ?? false {
                                Image(systemName: "arrow.down")
                                
                                    .id(episode.downloadItem?.id ?? UUID())
                            }
                            Text(episode.metaData?.episode?.playProgress.formatted() ?? "0.00")
                                .monospaced()
                            
                            
                        }
                        .font(.caption)
                        
                        
                        VStack(alignment: .leading){
                            HStack{
                                EpisodeCoverView(episode: episode)
                                    .frame(width: 50, height: 50)
                                VStack(alignment: .leading){
                                    Text(episode.podcast?.title ?? "")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    Text(episode.title)
                                        .font(.headline)
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.5)
                                }
                            }
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
                                HStack {
                                    
                                    if episode.metaData?.completionDate != nil {
                                        Image("custom.play.circle.badge.checkmark")
                                    } else {
                                        if episode.metaData?.calculatedIsAvailableLocally == true {
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
                                
                                Spacer()
                                Text((episode.publishDate?.formatted(.relative(presentation: .named)) ?? ""))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            .buttonStyle(.plain)
                            Spacer()
                            EpisodeControlView(episode: episode)
                                .modelContainer(modelContext.container)
                            
                        }
                        
                    }
                    .padding()
                    // .background(.ultraThinMaterial)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.thinMaterial)
                        // .shadow(radius: 3)
                    )
                    

                    
                
                
                
                
                
            }
        }
          
        

    }
    

}

