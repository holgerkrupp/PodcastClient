//
//  PlayerControllView.swift
//  Raul
//
//  Created by Holger Krupp on 27.06.25.
//
import SwiftUI


struct PlayerControllView: View {
    @Bindable private var player = Player.shared
    @State private var showTranscripts: Bool = false
    @State private var showFullTranscripts: Bool = false
    @State var showSpeedSetting:Bool = false
    
    
    
    var body: some View {
        if let episode = player.currentEpisode {
            VStack {
                
                HStack {
                    Spacer()
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
                    .buttonStyle(.plain)
                    .sheet(isPresented: $showSpeedSetting, content: {
                        VStack{
                            /*
                             Text("Adjust Sleeptimer")
                             Toggle(isOn: $player.sleeptimer.activated) {
                             Text("Activate Sleeptimer")
                             }
                             Stepper(value: $player.sleeptimer.minutes, in: 1...60, step: 1) {
                             Text(player.sleeptimer.secondsLeft?.secondsToHoursMinutesSeconds ?? "00:00")
                             }
                             .disabled(!player.sleeptimer.activated)
                             */
                            
                            
                            Text("Adjust Playback Speed")
                            Stepper(value: $player.playbackRate, in: 0.1...3.0, step: 0.1) {
                                Text("\(player.playbackRate.formatted())x")
                            }
                            
                        }.padding()
                            .presentationDragIndicator(.visible)
                            .presentationBackground(.ultraThinMaterial)
                            .presentationDetents([.fraction(0.5)])
                        
                    })
                    Spacer()
                    
                    
                }
                
                ZStack() {
                    Color.clear
                    
                    
                    Group{
                        if let chapterImage = player.currentChapter?.imageData {
                            ImageWithData(chapterImage)
                                .id(player.currentChapter?.id ?? UUID())
                                .scaledToFit()
                        }else{
                            EpisodeCoverView(episode: episode)
                                .id(episode.id)
                            
                                .scaledToFit()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    
                    .overlay(alignment: .bottom) {
                        if let transcriptLines = player.currentEpisode?.transcriptLines,
                           player.playPosition.isNormal, showTranscripts {
                            
                           // let decoder = TranscriptDecoder(transcriptFileContent)
                            
                            TranscriptView(transcriptLines: transcriptLines, currentTime: $player.playPosition)
                            
                            
                                .background(.ultraThinMaterial)
                            
                        }
                    }
                    .sheet(isPresented: $showFullTranscripts) {
                        if let transcriptLines = player.currentEpisode?.transcriptLines {
                            TranscriptListView(transcriptLines: transcriptLines)
                                .presentationDetents([.large])
                        }
                    }
                    
                }
                
                if episode.transcriptLines != nil {
                    HStack {
                        if showTranscripts{
                            Image("custom.quote.bubble.slash")
                                .onTapGesture(perform: {
                                    showTranscripts.toggle()
                                })
                        }else{
                            Image(systemName: "quote.bubble")
                                .onTapGesture(perform: {
                                    showTranscripts.toggle()
                                })
                        }
                        Spacer()
                        Image("custom.quote.bubble.rectangle.portrait")
                            .onTapGesture(perform: {
                                showFullTranscripts.toggle()
                            })
                    }
                }
                
                
                PlayerChapterView()
                
                
                Text("\(episode.title)")
                    .lineLimit(2)
                
                
                VStack {
                    PlayerProgressSliderView(value: $player.progress, allowTouch: false, sliderRange: 0...1)
                        .frame(height: 30)
                    
                    
                    HStack {
                        Text(player.playPosition.secondsToHoursMinutesSeconds ?? "00:00:00")
                            .monospacedDigit()
                            .font(.caption)
                        Spacer()
                        Text(player.remaining?.secondsToHoursMinutesSeconds ?? player.currentEpisode?.duration?.secondsToHoursMinutesSeconds ?? "")
                            .monospacedDigit()
                            .font(.caption)
                    }
                }
                
                
                HStack{
                    
                    Spacer()
                    Button(action:player.skipback){
                        Label {
                            Text("Skip Back")
                        } icon: {
                            Image(systemName: "15.arrow.trianglehead.counterclockwise")
                                .resizable()
                                .scaledToFit()
                            
                        }
                        .labelStyle(.iconOnly)
                        
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 30)
                    
                    Spacer()
                    Button(action: {
                        if player.isPlaying {
                            player.pause()
                        } else {
                            player.play()
                        }
                    }) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .resizable()
                            .scaledToFit()
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 30)
                    
                    
                    Spacer()
                    Button(action:player.skipforward){
                        Label {
                            Text("Skip Back")
                        } icon: {
                            Image(systemName: "30.arrow.trianglehead.clockwise")
                                .resizable()
                                .scaledToFit()
                            
                        }
                        .labelStyle(.iconOnly)
                        
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 30)
                    Spacer()
                    
                }
                .frame(height: 40)
                .tint(.primary)

                
            }
            .padding()
        }
    }
}
