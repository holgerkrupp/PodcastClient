import SwiftUI

struct PlayerView: View {
    @State private var player = Player.shared
    @State private var showTranscripts: Bool = true

    var body: some View {
        NavigationStack {
            
    
        VStack {
            if let episode = player.currentEpisode {
            ZStack(){
                Color.clear  // <- this is a stupid hack to macke the ZStack align the image on the top. if anyone from apple reads this: WHY ?????????
                
                
                player.coverImage
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .onTapGesture(perform: {
                        showTranscripts.toggle()
                    })
                    .overlay(alignment: .bottom) {
                        if let vttFileContent = player.currentEpisode?.transcriptData, player.playPosition.isNormal, showTranscripts{
                            NavigationLink(destination: TranscriptListView(vttContent: vttFileContent), label: {
                                TranscriptView(vttContent: vttFileContent, currentTime: $player.playPosition)
                                    .frame(maxWidth: .infinity)
                            })
                        }
                    }
                    

            }
          //  .frame(height: UIScreen.main.bounds.width/4) // Set height to match the width

          
                PlayerChapterView()
            
            
                Text("\(episode.title)")
   
                
                VStack{
                    
                    PlayerProgressSliderView(value: $player.progress, sliderRange: 0...1)
                        .frame(height: 30)
                    
                    HStack{
                        Text(player.playPosition.secondsToHoursMinutesSeconds ?? "00:00:00")
                            .monospacedDigit()
                        Spacer()
                        Text(player.remaining?.secondsToHoursMinutesSeconds ?? player.currentEpisode?.duration?.secondsToHoursMinutesSeconds ?? "")
                            .monospacedDigit()
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
}

#Preview {
    let episode = Episode(id: UUID(), title: "Test Episode", url: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!, podcast: Podcast(feed: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!))
    let _: () = Player.shared.currentEpisode = episode
    
    PlayerView()
}
