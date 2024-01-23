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
    @State var showSpeedSetting:Bool = false
    @State var showSleeptimerSetting:Bool = false

    
    var body: some View {

            VStack{
                
                player.coverImage
                    .scaledToFit()
                            
                
                    Text(player.currentEpisode?.title ?? "Here could be your Podcast Title")
                        .font(.title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.01)
                        .padding()
                    
                      PlayerChapterView()
                    
                    
                    
                
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
                 //   ProgressView(value: player.progress, total: 1.0)
                    
                    PlayerProgressSliderView(value: $player.progress, sliderRange: 0...1)
                        .frame(height: 30)
                    
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
                    
                    Button {
                        
                        showSpeedSetting = true
                        
                    } label: {
                        
                        Label {
                            Text("Playback Speed")
                        } icon: {
                            Image(systemName: "dial.medium")
                                .tint(.primary)
                        }
                        .labelStyle(.iconOnly)
                        
                       
                    }
                    .sheet(isPresented: $showSpeedSetting, content: {
                        VStack{
                            Text("Adjust Playback Speed")
                            Stepper(value: $player.settings.playbackSpeed, in: 0.1...3.0, step: 0.1) {
                                Text("\(player.settings.playbackSpeed.formatted())x")
                            }
                            .padding()
                        }
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.thinMaterial)
                        .presentationDetents([.fraction(0.2)])
                        .presentationCompactAdaptation(
                            horizontal: .popover,
                            vertical: .sheet)
                    })
                    
                    
                    

                        
                    Spacer()
                    Image(systemName: "gear")
                    Spacer()
                    
                    
                    Button {
                        
                        showSleeptimerSetting = true
                        
                    } label: {
                        
                        Label {
                            Text("Sleeptimer")
                        } icon: {
                            Image(systemName: "moon.zzz")
                                .tint(.primary)
                        }
                        .labelStyle(.iconOnly)
                        
                        
                    }
                    .sheet(isPresented: $showSleeptimerSetting, content: {
                        VStack{
                            Text("Adjust Sleeptimer")
                            Toggle(isOn: $player.sleeptimer.activated) {
                                Text("Activate Sleeptimer")
                            }
                            Stepper(value: $player.sleeptimer.minutes, in: 1...60, step: 1) {
                                Text(player.sleeptimer.secondsLeft?.secondsToHoursMinutesSeconds ?? "00:00")
                            }
                            .disabled(!player.sleeptimer.activated)
                            
                            
                        }.padding()
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.thinMaterial)
                        .presentationDetents([.fraction(0.2)])
                        .presentationCompactAdaptation(
                            horizontal: .popover,
                            vertical: .sheet)
                    })
                    
                    
                    
                }
                
                .padding()
                
            }
            .background(Color("backgroundColor"))
  
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
            
            Image(systemName: playerPaused ? "play.fill" : "pause.fill")
                .resizable()
                .aspectRatio(1.0, contentMode: .fit)

            
            
        }
        .onAppear(){
            playerPaused = !player.isPlaying
        }
        .onChange(of: player.isPlaying) {
            playerPaused = !player.isPlaying
        }
    }
}
