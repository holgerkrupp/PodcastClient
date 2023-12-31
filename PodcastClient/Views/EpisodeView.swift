//
//  PodcastView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 06.12.23.
//

import SwiftUI
import SwiftData

struct EpisodeView: View {
    

    private let coverSize:CGFloat = 100

    @Environment(\.modelContext) var modelContext
    @Query var episodes: [Episode]
    var episode: Episode? { episodes.first}
    
    
    
    init(for episodeID: PersistentIdentifier) {
        
        
        self._episodes = Query(filter: #Predicate<Episode> {
            $0.persistentModelID == episodeID
        })
        
    }
    
    
    var body: some View {
        if let episode{
            List{
                Section {

                                
                    VStack{
                        HStack{
                          
                            if episode.finishedPlaying == true{
                                Image(systemName: "circle.fill")
                            }else{
                                Image(systemName: "circle")
                            }
                            
                            
                            if let imageULR = episode.image{
                                ImageWithURL(imageULR)
                                    .scaledToFit()
                                    .frame(width: coverSize, height: coverSize)
                                
                            }else if let imageULR = episode.podcast?.coverURL{
                                ImageWithURL(imageULR)
                                    .scaledToFit()
                                    .frame(width: coverSize, height: coverSize)
                            }else{
                                Image(systemName: "mic.fill")
                                    .scaledToFit()
                                    .frame(width: coverSize, height: coverSize)
                            }
                            
                            VStack{
                                //         Text(episode.title ?? "")
                                Text(episode.subtitle ?? "")
                                Text(episode.pubDate?.formatted() ?? "").font(.caption)
                            }
                        }
                        EpisodePlayProgressView(episode: episode)
                            .frame(maxWidth: .infinity, maxHeight: 30)
                        Spacer()
                        EpisodeControlView(episode: episode)
                        
                    //    EpisodeStatusIcon(episode: episode)
                        
                        
                        
     
                        
                        
                    }
                    
                    
                }
                
                Text(episode.desc?.toDetectedAttributedString() ?? "")
                /*
                 Section {
                 ForEach(episode.chapters){ chapter in
                 HStack{
                 
                 
                 Toggle(isOn: chapter.shouldPlay, label: {
                 Text(chapter.title.wrappedValue)
                 })
                 .padding()
                 .toggleStyle(.switch)
                 }
                 }
                 } header: {
                 Text("Chapters")
                 }
                 */
                
                
            }
            .listStyle(.plain)
            .navigationTitle(Text(episode.title ?? ""))
            
        }else{
            Text("error loading episode")
    }
        
    }
}

struct EpisodeMiniView: View {
    
    @Environment(\.modelContext) var modelContext

    // @Environment(Episode.self) private var episode
    
    var formatStyle = Date.RelativeFormatStyle()
 
    var model: EpisodeListItemModel
    
    
    
    var body: some View {
        NavigationLink {
            EpisodeView(for: model.episode.persistentModelID)
                .modelContext(modelContext)
            
        }label:{
            VStack{
                HStack{
                    VStack{
                        Spacer()
                        if model.episode.finishedPlaying == true{
                            Image(systemName: "circle.fill")
                        }else{
                            Image(systemName: "circle")
                        }
                        Spacer()
                        EpisodeStatusIcon(episode: model.episode)
                        Spacer()
                    }
                    
                    if let imageULR = model.episode.image{
                        ImageWithURL(imageULR)
                            .scaledToFit()
                            .frame(width: 50, height: 50)
                        
                    }else if let imageULR = model.episode.podcast?.coverURL{
                        ImageWithURL(imageULR)
                            .scaledToFit()
                            .frame(width: 50, height: 50)
                    }else{
                        Image(systemName: "mic.fill")
                            .scaledToFit()
                            .frame(width: 50, height: 50)
                    }
                    
                    VStack(alignment: .leading){
                        Spacer()
                        Text(model.episode.title ?? "")
                        Spacer()
                        HStack{
                            //   Text(episode.pubDate?.formatted(date: .numeric, time: .omitted) ?? "--")
                            Text(model.episode.pubDate?.formatted(formatStyle) ?? "--")
                            Spacer()
                            Text(model.episode.duration?.secondsToHoursMinutesSeconds ?? "")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        
                        
                        
                        if model.episode.playPosition > 0.0{
                            EpisodePlayProgressView(episode: model.episode)
                                .frame(maxWidth: .infinity, maxHeight: 30)
                        }
                        
                    }
                }
                
            }
            
            
        }
    }
}

@Observable
class EpisodeListItemModel {
    var episode: Episode
    
    init(episode: Episode) {
        self.episode = episode
    }
}



struct EpisodeStatusIcon:View{
    @State var episode:Episode

    
    
    
    var body: some View {
        if episode.isAvailableLocally{
            Image(systemName: "externaldrive.badge.checkmark")
                .scaledToFit()
                .frame(width: 10, height: 10)
        }else if episode.downloadStatus.isDownloading{
            ProgressView(value: episode.downloadStatus.downloadProgress)
                .progressViewStyle(.circular)
                .frame(width: 10, height: 10)
            Text(episode.downloadStatus.downloadProgress.rounded().formatted())
        }else{
            Image(systemName: "cloud")
                .scaledToFit()
                .frame(width: 10, height: 10)
        }
    }
}


struct EpisodePlayProgressView:View{
   
    @State var episode:Episode

    var body: some View {
            HStack{
                ProgressView(value: episode.progress, total: 1.0)
                        .progressViewStyle(.linear)
                if let duration = episode.duration, episode.playPosition > 0.0{
                    
                    if (duration - episode.playPosition) > 0.9{
                        
                        Text("\((duration - episode.playPosition).secondsToHoursMinutesSeconds ?? "")")
                            .monospaced()
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                    }else{
                        Image(systemName: "checkmark.circle")
                            .foregroundColor(.secondary)
                    }
                }
        }
    }
    
}


