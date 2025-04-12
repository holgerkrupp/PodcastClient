import SwiftUI

struct PlayerView: View {
    @State private var player = Player.shared
    @State private var showTranscripts: Bool = true
    let fullSize: Bool

    var body: some View {
        NavigationStack {
            VStack {
                if let episode = player.currentEpisode {
                    ZStack() {
                        Color.clear
                        
                        if fullSize {
                            player.coverImage
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .onTapGesture(perform: {
                                    showTranscripts.toggle()
                                })
                                .overlay(alignment: .bottom) {
                                    if let vttFileContent = player.currentEpisode?.transcriptData,
                                       player.playPosition.isNormal,
                                       showTranscripts {
                                        NavigationLink(destination: TranscriptListView(vttContent: vttFileContent), label: {
                                            TranscriptView(vttContent: vttFileContent, currentTime: $player.playPosition)
                                                .frame(maxWidth: .infinity)
                                        })
                                    }
                                }
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
}

#Preview {
    let episode = Episode(id: UUID(), title: "Test Episode", url: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!, podcast: Podcast(feed: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!))
    let _: () = Player.shared.currentEpisode = episode
    
    PlayerView(fullSize: true)
}
