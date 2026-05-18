import SwiftUI
import RichText



struct PlayerView: View {
    @Bindable private var player = Player.shared
    @State private var showTranscripts: Bool = false
    @State private var showFullTranscripts: Bool = false
    @State var showSpeedSetting:Bool = false



    let fullSize: Bool

    var body: some View {
            
            
                if let episode = player.currentEpisode {
                 
                    
                   
                
                           
                            
                            Group{
                                if fullSize == true {
                                    ScrollView(.vertical) {
                                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                                            PlayerControllView(showPrimaryTransportControls: false)
                                                .padding()

                                            Section {
                                                HStack {

                                                    if let episodeLink = episode.link {


                                                        Link(destination: episodeLink) {
                                                            Label("Open in Browser", systemImage: "safari")
                                                                .labelStyle(.iconOnly)
                                                        }
                                                        .buttonStyle(.glass(.clear))
                                                     //   .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 20.0))
                                                    }
                                                    Spacer()
#if DEBUG
                                                    NavigationLink(destination: EpisodeDebugMetadataView(episode: episode)) {
                                                        Image(systemName: "ladybug")
                                                            .imageScale(.small)
                                                    }
                                                    .buttonStyle(.glass(.clear))
                                                    .frame(height: 30)
                                                    .accessibilityLabel("Episode debug metadata")
                                                    Spacer()
#endif

                                                    if player.canSwitchCurrentEpisodeMedia {
                                                        Button {
                                                            Task {
                                                                await player.switchCurrentEpisodeMedia()
                                                            }
                                                        } label: {
                                                            Label {
                                                                Text(player.currentPlaybackIsVideo ? "Switch to Audio" : "Switch to Video")
                                                            } icon: {
                                                                Image(systemName: player.currentPlaybackIsVideo ? "waveform" : "play.rectangle")
                                                                    .resizable()
                                                                    .scaledToFit()
                                                            }
                                                            .labelStyle(.iconOnly)
                                                        }
                                                        .buttonStyle(.glass)
                                                        .buttonBorderShape(.circle)
                                                        .frame(height: 30)
                                                        .accessibilityLabel(player.currentPlaybackIsVideo ? "Switch to audio" : "Switch to video")
                                                        .accessibilityHint("Changes the current episode between the audio enclosure and alternate video stream")
                                                    }
                                                    

                                                    Spacer()
                                                    if let url = episode.deeplinks?.first ?? episode.link {

                                                        let positionedURL: URL = {
                                                            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
                                                            var queryItems = components.queryItems ?? []
                                                            // Remove old 't' if exists
                                                            queryItems.removeAll { $0.name == "t" }
                                                            let playPosition = Int(player.playPosition)
                                                            queryItems.append(URLQueryItem(name: "t", value: "\(playPosition)"))
                                                            components.queryItems = queryItems
                                                            return components.url ?? url
                                                        }()

                                                      //  shareURL = IdentifiableURL(url: url)
                                                        ShareLink(item: positionedURL) { Label("Share", systemImage: "square.and.arrow.up")
                                                            .labelStyle(.iconOnly) }
                                                        .buttonStyle(.glass(.clear))
                                                        .accessibilityLabel("Share episode link at current time")
                                                        .accessibilityHint("Opens the share sheet with the current playback timestamp")

                                                    }


                                                }
                                                .padding()

                                                RichText(html: episode.content ?? episode.desc ?? "")
                                                    .linkColor(light: Color.secondary, dark: Color.secondary)
                                                    .backgroundColor(.transparent)
                                                    .padding()
                                            } header: {
                                                PlayerPrimaryTransportControlsView(includeBookmark: true)
                                                    .tint(.primary)
                                                    .padding(.horizontal)
                                                    .padding(.top, 20)
                                                    .padding(.bottom, 6)
                                                    .frame(maxWidth: .infinity)
                                                    .zIndex(3)
                                            }
                                        }
                                    }
                                   
                                } else {
                                    VStack(spacing: 0) {
                                        PlayerControllView()
                                            .padding()
#if DEBUG
                                        NavigationLink(destination: EpisodeDebugMetadataView(episode: episode)) {
                                            Image(systemName: "ladybug")
                                                .imageScale(.small)
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Episode debug metadata")
#endif
                                    }
                                }
                            }
                            
                                .background(
                                    
                                    CoverImageView(episode: episode)
                                        .aspectRatio(1, contentMode: .fill)
                                        .scaledToFill()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity) // Ensure it takes up all available space
                                                        .ignoresSafeArea(.all) // Crucial: extends the image behind safe areas (like under the status bar)
                                                        
                                        .blur(radius: 100)
                                        .opacity(0.5)
                                      
                                    
                                )
                                
                              
                            
                        .ignoresSafeArea()
                        
                        
    
                       
    
                    
                    

                } else {
                    PlayerEmptyView()
                }
            

        
       
    }
}


#Preview {
    @Previewable @State var fullSize: Bool = false
    let episode = Episode(title: "Test Episode", url: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!, podcast: Podcast(feed: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!))
    //episode.imageURL = URL(string: "https://compendion.net/dirtyminutesleft/wp-content/uploads/sites/3/2020/04/Logo-compendion-DML2-3k.jpg")!
    let _: () = Player.shared.currentEpisode = episode
    Toggle("Full Size", isOn: $fullSize)
    PlayerView(fullSize: fullSize)

}
