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
                    if let assets = episode.assets {
                    HStack{
                        ForEach(assets){ asset in
                            Menu{
                                AssetMetaDataView(asset: asset)
                            }label:{
                                Image(systemName: "line.3.horizontal")
                            }
                            
                        }
                                }
                                }
                    VStack{
                        HStack{
                            
                            if episode.playStatus?.finishedPlaying == true{
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
    
    
    // @Environment(Episode.self) private var episode
    
    var formatStyle = Date.RelativeFormatStyle()
 
    var model: EpisodeListItemModel
    
    
    
    var body: some View {
        
            VStack{
                HStack{
                    if model.episode.playStatus?.finishedPlaying == true{
                        Image(systemName: "circle.fill")
                    }else{
                        Image(systemName: "circle")
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
                            Text(model.episode.duration ?? "")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        
                        HStack{
                            EpisodeStatusIcon(episode: model.episode)
                            Spacer()

                    
                            EpisodePlayProgressView(episode: model.episode)
                            
                                .environment(Player.shared)
                                .frame(maxWidth: .infinity, maxHeight: 30)
                      
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
    @Environment(Player.self) private var player
    @Environment(\.modelContext) var modelContext

    @State var episode:Episode

    var body: some View {
        
        
        
        NavigationLink {
            EpisodeView(for: episode.persistentModelID)
                .modelContext(modelContext)
            
        }label:{
            VStack{
                HStack{
                    if player.currentEpisode == episode{
                        
                        ProgressView(value: player.progress, total: 1.0)
                            .progressViewStyle(.linear)
                        
                    }else{
                        
                        ProgressView(value: episode.progress, total: 1.0)
                            .progressViewStyle(.linear)
                        
                    }
                    
                }
                
                
            }
        }
        
        

    }
    
}


struct AssetMetaDataView: View{
    
    var asset: Asset
    
    var body: some View {
        VStack{
            HStack{
                Text("Title")
                Text(asset.title ?? "")
            }
            HStack{
                Text("Link")
                Text(asset.link?.absoluteString ?? "")
            }
            HStack{
                Text("Desc")
                Text(asset.desc ?? "")
            }
            HStack{
                Text("Desc")
                Text(asset.length?.formatted() ?? "")
            }
            HStack{
                Text("Type")
                Text(asset.type.debugDescription)
            }
        }
    }
}
