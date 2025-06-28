import SwiftUI
import GlowEffects


struct PlayerView: View {
    @Bindable private var player = Player.shared
    @State private var showTranscripts: Bool = false
    @State private var showFullTranscripts: Bool = false
    @State var showSpeedSetting:Bool = false
   

    let fullSize: Bool

    var body: some View {
            
            
                if let episode = player.currentEpisode {
                    ZStack{
                        
                        // Background layer
                        
                        
                        
                        EpisodeCoverView(episode: episode)
                           
                            .aspectRatio(contentMode: .fill)
                            .scaledToFill()
                        
                        //       .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                        
                            .frame(width: UIScreen.main.bounds.width * 0.9, height: (fullSize && player.currentEpisode != nil) ? UIScreen.main.bounds.height * 1 : 80)
                            .ignoresSafeArea(.all, edges: .bottom)
                        // .animation(.easeInOut(duration: 0.3), value: episode.playProgress)
                        
                        Group{
                            if fullSize {
                                ScrollView{
                                    Spacer(minLength: 20)
                                    PlayerControllView()
                                        .padding()
                                    EpisodeDetailView(episode: episode)
                                    
                                }
                                
                            }else{
                                PlayerControllView()
                            }
                        }
                        
                            .background(
                                
                                Rectangle()
                                    .fill(.thinMaterial)
                                
                            )
                            
                          
                        }
                    

                   

                } else {
                    PlayerEmptyView()
                }
            

        
       
    }
}

#Preview {
    @Previewable @State var fullSize: Bool = false
    let episode = Episode(id: UUID(), title: "Test Episode", url: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!, podcast: Podcast(feed: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!))
    //episode.imageURL = URL(string: "https://compendion.net/dirtyminutesleft/wp-content/uploads/sites/3/2020/04/Logo-compendion-DML2-3k.jpg")!
    let _: () = Player.shared.currentEpisode = episode
    Toggle("Full Size", isOn: $fullSize)
    PlayerView(fullSize: fullSize)

}
