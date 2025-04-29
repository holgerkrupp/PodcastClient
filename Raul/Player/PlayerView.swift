import SwiftUI


struct PlayerView: View {
    @State private var player = Player.shared
    @State private var showTranscripts: Bool = false
    @State private var showFullTranscripts: Bool = false
    @State var showSpeedSetting:Bool = false
   

    let fullSize: Bool

    var body: some View {
            
            VStack {
                if let episode = player.currentEpisode {
                    if fullSize {
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
                    }
                    ZStack() {
                        Color.clear
                        
                        if fullSize {
                            player.coverImage
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                               
                                .overlay(alignment: .bottom) {
                                    if let vttFileContent = player.currentEpisode?.transcriptData,
                                       player.playPosition.isNormal, showTranscripts {
                                       
                                            
                                      
                                        TranscriptView(vttContent: vttFileContent, currentTime: $player.playPosition)
                                               

                                       
                                        .background(.ultraThinMaterial)
                                       
                                    }
                                }
                                .sheet(isPresented: $showFullTranscripts) {
                                    if let vttFileContent = player.currentEpisode?.transcriptData {
                                        TranscriptListView(vttContent: vttFileContent)
                                            .presentationDetents([.large])
                                    }
                                }
                        }
                    }
                    
                    if fullSize, episode.transcriptData != nil {
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
                    
                    if fullSize {
                        PlayerChapterView()
                    }
                    
                    Text("\(episode.title)")
                        .lineLimit(fullSize ? nil : 1)
                    
                    if fullSize {
                        VStack {
                            PlayerProgressSliderView(value: $player.progress, sliderRange: 0...1)
                                .frame(height: 30)
                            
                            HStack {
                                Text(player.playPosition.secondsToHoursMinutesSeconds ?? "00:00:00")
                                    .monospacedDigit()
                                Spacer()
                                Text(player.remaining?.secondsToHoursMinutesSeconds ?? player.currentEpisode?.duration?.secondsToHoursMinutesSeconds ?? "")
                                    .monospacedDigit()
                            }
                        }
                        
                    }
                    
                    Button(action: {
                        if player.isPlaying {
                            player.pause()
                        } else {
                            player.play()
                        }
                    }) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("No episode playing.")
                }
            }
            .padding()
            .frame(width: UIScreen.main.bounds.width * 0.9, height: (fullSize && player.currentEpisode != nil) ? UIScreen.main.bounds.height * 0.5 : 80)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.thinMaterial)
                    .shadow(radius: 3)
            )
        
       
    }
}

#Preview {
    let episode = Episode(id: UUID(), title: "Test Episode", url: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!, podcast: Podcast(feed: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!))
    let _: () = Player.shared.currentEpisode = episode
    
    PlayerView(fullSize: true)

}
