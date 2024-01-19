//
//  PlayerView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 13.01.24.
//

import SwiftUI
import AVFoundation

struct PlayerView: View {
   @State var player = Player.shared

    
    
    var body: some View {

            VStack{
                
                player.coverImage
                    .scaledToFit()
                            
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
                            Text("Skip Back")
                        } icon: {
                            Image(systemName: player.settings.skipBack.backString)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .tint(.primary)
                            
                        }
                        .labelStyle(.iconOnly)
                        
                    }
                    
                    
                    
                    Spacer()
                    PlayButtonView(playerPaused: !player.isPlaying, player: player)
                        .frame(width: 60.0, alignment: .center)
                        .tint(.primary)

                    Spacer()
                    
                    
                    Button(action:player.skipforward){
                        Label {
                            Text("Skip Forward")
                        } icon: {
                            Image(systemName: player.settings.skipForward.forwardString)
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
                    .frame(height: 30)
                HStack{
                    
                    Picker(selection: $player.settings.playbackSpeed) {
                        ForEach (PlayBackSpeed.allCases, id:\.self) { speed in
                            Text(speed.description)
                                .monospacedDigit()
                        }
                    } label: {
                        HStack{
                            Text("Playback Speed")
                        }
                    }
                        
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

struct PlayButtonView : View {
    @State var playerPaused = true
    @State var player: Player
    var body: some View {
        Button(action: {
            self.playerPaused.toggle()
            if self.playerPaused {
                self.player.pause()
            }
            else {
                self.player.play()
            }
        }) {
            
            Image(systemName: playerPaused ? "play" : "pause")
                .resizable()
                .aspectRatio(1.0, contentMode: .fit)

            
            
        }
        .onAppear(){
            playerPaused = !player.isPlaying
        }
    }
}
