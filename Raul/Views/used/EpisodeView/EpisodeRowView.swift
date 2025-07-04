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
    @State var episode: Episode
    @State private var image: Image?
    
    var body: some View {

            VStack(alignment: .leading) {
                ZStack{
                    
                    EpisodeCoverView(episode: episode)
                        .scaledToFill()
                        .id(episode.id)
                        
                        .frame(width: UIScreen.main.bounds.width * 0.9, height: 200)
                        .clipped()
                    
                    
                    GeometryReader { geometry in
                        // Background layer
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.5))
                            .frame(width: geometry.size.width * episode.maxPlayProgress)
                    }
                    .padding()
                
                    
                    VStack{
                        Button {
                            Task{
                                await EpisodeActor(modelContainer: modelContext.container).transcribe(episode.url)
                            }
                        } label: {
                            Text("Transcribe")
                        }
                        .buttonStyle(.glass)


                        
                        VStack(alignment: .leading){
                            HStack{
                                EpisodeCoverView(episode: episode)
                                    .frame(width: 50, height: 50)
                                
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
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.5)
                                }
                            }
                            .onTapGesture(){
                            //   presentingModal = true
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
                                        if fileManager.isDownloaded(episode.localFile) == true {
                                            Image(systemName: style.sfSymbolName)
                                        }else{
                                            Image(systemName: "cloud")
                                        }
                                    }
                                    
                                    if episode.chapters.count > 0 {
                                        Image(systemName: "list.bullet")
                                    }
                                    if episode.externalFiles.contains(where: {$0.category == .transcript}) || episode.transcriptData != nil {
                                        
                                        Image(systemName: "quote.bubble")
                                        
                                       
                                    }
                                    
                                 
                                    
                                        Spacer()
                                    
                           
                                  
                                     DownloadControllView(episode: episode, showDelete: false)
                                        .symbolRenderingMode(.hierarchical)
                                       // .scaledToFit()
                                        .padding(8)
                                        .foregroundColor(.accentColor)
                                     //   .minimumScaleFactor(0.5)
                                        .labelStyle(.iconOnly)
                                    

                                }
                                .frame(maxWidth: .infinity, maxHeight: 30)
                                
                                
                            }

                            .buttonStyle(.plain)
                         
                            EpisodeControlView(episode: episode)
                                .modelContainer(modelContext.container)
                                .frame(height: 50)
                                .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))

                           
                        }
                        
                    }
                    .padding()
                    // .background(.ultraThinMaterial)
                    .background(
                        Rectangle()
                            .fill(.ultraThinMaterial)
                        // .shadow(radius: 3)
                    )
                   
                   
                
            }
        }
            .sheet(isPresented: $presentingModal, content: {
                EpisodeDetailView(episode: episode)
                  
            })
          
        

    }
    

}

