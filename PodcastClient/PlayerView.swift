//
//  PlayerView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 13.01.24.
//

import SwiftUI

struct PlayerView: View {
   var player = Player.shared

    
    
    var body: some View {

            VStack{
                
                player.coverImage
                    .scaledToFit()
                
                Text(player.chapterRemaining?.secondsToHoursMinutesSeconds ?? "")
                
                VStack{
                    Text(player.currentEpisode?.title ?? "Here could be your Podcast Title")
                        .font(.title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.01)
                        .padding()
                    
                       if player.currentEpisode?.chapters.count ?? 0 > 0{
                    HStack{
                        Spacer()
                            .frame(width: 50)
                        Button {
                            player.skipToChapterStart()
                        } label: {
                            SkipBackView()
                                .aspectRatio(contentMode: .fit)
                                .tint(.primary)
                        }

                        

                        Spacer()
                        Text(player.currentChapter?.title ?? "no chapter title")
                        Spacer()
                        Button {
                            player.skipToNextChapter()
                        } label: {
                            SkipNextView(progress: player.chapterProgress ?? 0.0)
                                .aspectRatio(contentMode: .fit)
                                .tint(.primary)
                        }


                        Spacer()
                            .frame(width: 50)
                    }
                    .frame(height: 30)
                         }
                    
                    
                    
                }
                Spacer()
                HStack{
                    Spacer()
                    Button(action:player.skipback){
                        Label {
                            Text("Skip Back 45 seconds")
                        } icon: {
                            Image(systemName: "gobackward.45")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .tint(.primary)
                            
                        }
                        .labelStyle(.iconOnly)
                        
                    }
                    
                    
                    
                    Spacer()
                    
                    
                    Button(action:player.playPause){
                        Label {
                            Text("Play")
                        } icon: {
                            player.playPauseButton
                                .aspectRatio(contentMode: .fit)
                                .tint(.primary)
                        }
                        .labelStyle(.iconOnly)
                        
                    }
                    
                    Spacer()
                    
                    
                    Button(action:player.skipforward){
                        Label {
                            Text("Skip Forward 45 seconds")
                        } icon: {
                            Image(systemName: "goforward.45")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .tint(.primary)
                            
                        }
                        .labelStyle(.iconOnly)
                        
                    }
                    Spacer()
                }
                .frame(height: 40.0, alignment: .center)
                Spacer()
                VStack{
                    ProgressView(value: player.progress, total: 1.0)
                    
                    HStack{
                        Text(player.playPosition.secondsToHoursMinutesSeconds ?? "00:00:00")
                            .monospacedDigit()
                        Spacer()
                        Text(player.remaining?.secondsToHoursMinutesSeconds ?? "-")
                            .monospacedDigit()
                    }
                }
                .padding()
                Spacer()
                    .frame(height: 50)
                HStack{
                    Text(player.rate.description)
                        .monospacedDigit()
                    Spacer()
                    Image(systemName: "gear")
                    Spacer()
                    Image(systemName: "moon.zzz")
                }
                
                .padding()
                
            }
  
    }
}

#Preview {
    PlayerView()
}
