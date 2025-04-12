import SwiftUI

struct PlayerView: View {
    @State private var player = Player.shared
    @State private var showTranscripts: Bool = false
    @State private var showFullTranscripts: Bool = false
    let fullSize: Bool

    var body: some View {
        
            VStack {
                if let episode = player.currentEpisode {
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
                    
                    if fullSize {
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
                } else {
                    Text("No episode playing.")
                }
            }
            .padding()
           
        
       
    }
}

#Preview {
    let episode = Episode(id: UUID(), title: "Test Episode", url: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!, podcast: Podcast(feed: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!))
    let _: () = Player.shared.currentEpisode = episode
    
    PlayerView(fullSize: true)

}
