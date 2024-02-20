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
    @State private var currentTime: Double = 0
    @State private var showTranscripts: Bool = false


    
    var body: some View {

            VStack{
                ZStack(alignment: .top){
                    Color.clear  // <- this is a stupid hack to macke the ZStack align the image on the top. if anyone from apple reads this: WHY ?????????
                    
                    
                    player.coverImage
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .onTapGesture(perform: {
                            showTranscripts.toggle()
                        })
                        

                }
                .frame(height: UIScreen.main.bounds.width) // Set height to match the width
                .overlay(alignment: .bottom) {
                    if let vttFileContent = player.currentEpisode?.transcriptData, player.playPosition.isNormal, showTranscripts{
                        
                        TranscriptView(vttContent: vttFileContent, currentTime: $player.playPosition)
                            .frame(maxWidth: .infinity)
                        
                    }
                }

               

                            
                
                    Text(player.currentEpisode?.title ?? "Here could be your Podcast Title")
                        .font(.title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.01)
                        .padding()
                    
                      PlayerChapterView()
                    
                    
                    
                
              
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
                            Text("Playback Settings")
                        } icon: {
                            
                                Image(systemName: "gear")
                                    .tint(.primary)
                               
                        }
                        .labelStyle(.iconOnly)
                        
                       
                    }
                    .sheet(isPresented: $showSpeedSetting, content: {
                        VStack{
                            
                            Text("Adjust Sleeptimer")
                            Toggle(isOn: $player.sleeptimer.activated) {
                                Text("Activate Sleeptimer")
                            }
                            Stepper(value: $player.sleeptimer.minutes, in: 1...60, step: 1) {
                                Text(player.sleeptimer.secondsLeft?.secondsToHoursMinutesSeconds ?? "00:00")
                            }
                            .disabled(!player.sleeptimer.activated)
                            
                            
                            
                            Text("Adjust Playback Speed")
                            Stepper(value: $player.rate, in: 0.1...3.0, step: 0.1) {
                                Text("\(player.settings.playbackSpeed.formatted())x")
                            }
                            
                        }.padding()
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.ultraThinMaterial)
                        .presentationDetents([.fraction(0.5)])
                      
                    })
                    
                    
                    

                        
                    Spacer()
                    
                    if let skip = (player.currentEpisode?.events?.last(where: { event in
                        event.date < Date().addingTimeInterval(60*5) &&
                        event.type == .skip
                    })) {
                        Button{
                            player.undo(skip: skip)
                        } label: {
                            
                            Label {
                                Text("Undo Skip")
                            } icon: {
                                Image(systemName: "arrow.uturn.backward")
                                    .tint(.primary)
                            }
                            .labelStyle(.iconOnly)
                            
                            
                        }
                    }
                    
                    


                    Spacer()
                    
                    if let link = player.currentEpisode?.link{
                        ShareLink(item: link) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .labelStyle(.iconOnly)
                        }
                    }

                    Spacer()
                    Button{
                        player.bookmark()
                    } label: {
                        
                        Label {
                            Text("Create Bookmark")
                        } icon: {
                            Image(systemName: "bookmark")
                                .tint(.primary)
                        }
                        .labelStyle(.iconOnly)
                    }
                    Spacer()
                    if player.currentEpisode?.transcriptData != nil{
                        Button {
                            
                            showTranscripts.toggle()
                            
                        } label: {
                            
                            Label {
                                Text("Show Transcript")
                            } icon: {
                                Image(systemName: showTranscripts == false ? "captions.bubble" : "captions.bubble.fill")
                                    .tint(.primary)
                            }
                            .labelStyle(.iconOnly)
                            
                            
                        }
                    }
                    /*
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
                        .presentationBackground(.ultraThinMaterial)
                        .presentationDetents([.fraction(0.2)])
                      
                    })
                    */
                    
                    
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
