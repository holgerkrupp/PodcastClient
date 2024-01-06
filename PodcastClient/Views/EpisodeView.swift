//
//  PodcastView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 06.12.23.
//

import SwiftUI
import SwiftData

struct EpisodeView: View {
    
    @Environment(\.modelContext) var modelContext
   // @State var episode:Episode
    @Environment(Episode.self) private var episode
    private let coverSize:CGFloat = 100

    
    var body: some View {
        List{
            Section {
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
                            Text(episode.title ?? "")
                            Text(episode.subtitle ?? "")
                        }
                    }
                    Spacer()
                    EpisodeControlView()
                        .environment(episode)
                    
                    EpisodeStatusIcon()
                        .environment(episode)
                    
                    
                    
                    HStack{
                        Button {
                            
                            Player.shared.currentEpisode = episode
                        } label: {
                            if episode.isAvailableLocally {
                                Text("Play Now")
                            }else{
                                Text("Stream Now")
                            }
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        if !episode.isAvailableLocally {
                            Button {
                                episode.download()
                            } label: {
                                Text("Download")
                                
                                
                            }
                            .buttonStyle(.bordered)
                        }else{
                            Button {
                                episode.removeFile()
                            } label: {
                                Text("Delete")
                                
                                
                            }
                            .buttonStyle(.bordered)
                        }
                    }


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
       
    }
}

struct EpisodeMiniView: View {
    

  //  var episode:Episode
    @Environment(Episode.self) private var episode

    var formatStyle = Date.RelativeFormatStyle()
    
    
    
    var body: some View {
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
                        .frame(width: 50, height: 50)
                    
                }else if let imageULR = episode.podcast?.coverURL{
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
                    Text(episode.title ?? "")
                    Spacer()
                    HStack{
                        //   Text(episode.pubDate?.formatted(date: .numeric, time: .omitted) ?? "--")
                        Text(episode.pubDate?.formatted(formatStyle) ?? "--")
                        Spacer()
                        Text(episode.duration ?? "")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    
                    HStack{
                        EpisodeStatusIcon()
                            .environment(episode)
                        Spacer()
                        //    ProgressView(value: (episode.playStatus?.playpostion ?? 0.0)/(episode.durationAsDouble ?? 300), total: 1.0)
                        EpisodePlayProgressView()
                            .environment(episode)
                            .environment(Player.shared)
                            .frame(maxWidth: .infinity, maxHeight: 30)
                        
                    }
                }
            }

        }
    }

}

struct EpisodeStatusIcon:View{
    @Environment(Episode.self) private var episode
    
    
    
    
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
    @Environment(Episode.self) private var episode
    var body: some View {
       
            if player.currentEpisode == episode{
                
                ProgressView(value: player.progress, total: 1.0)
                    .progressViewStyle(.linear)
                
            }else{
                ProgressView(value: episode.progress, total: 1.0)
                    .progressViewStyle(.linear)
                
            }
            
        
        
    }
    
}
