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
    @State var episode:Episode
    
    private let coverSize:CGFloat = 200

    
    var body: some View {
        List{
            Section {
                VStack{
                    HStack{
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
                    HStack{
                        Button {
                            
                            Player.shared.currentEpisode = episode
                            Player.shared.playPause()
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
                        }
                    }


                }
                
                    
                    }
            
            Text(episode.desc?.toDetectedAttributedString() ?? "")
            
            Section {
                                ForEach($episode.chapters){ chapter in
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

            

            }
        .listStyle(.plain)
       
    }
}

struct EpisodeMiniView: View {
    

    var episode:Episode
    
    var formatStyle = Date.RelativeFormatStyle()
    
    
    
    var body: some View {
        HStack{
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
                Spacer()
            }
        }
    }

}
