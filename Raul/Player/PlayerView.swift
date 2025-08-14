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
                    GeometryReader { geometry in
                        ZStack{
                            
                            // Background layer
                            
                            
                            
                            CoverImageView(episode: episode)
                               
                              
                                .aspectRatio(1, contentMode: .fill)
                                .scaledToFill()
                            
                           
                            
                                .frame(width: geometry.size.width * 0.9, height: (fullSize && player.currentEpisode != nil) ? geometry.size.height : 80)
                                .ignoresSafeArea(.all, edges: .bottom)
                           
                            
                            Group{
                                if fullSize == true {
                                    VStack{
                                
                                    ScrollView([.vertical]){
                                        Spacer(minLength: 20)
                                        PlayerControllView()
                                            .padding()
                                        
                                        if let episodeLink = episode.link {
                                            Link(destination: episodeLink) {
                                                Label("Open in Browser", systemImage: "safari")
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .padding()
                                        }
                                        
                                        RichText(html: episode.content ?? episode.desc ?? "")
                                            .linkColor(light: Color.secondary, dark: Color.secondary)
                                            .richTextBackground(.clear)
                                            .padding()
                                            
                                          
                                        
                                    }
                                }
                                    .padding(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
                                }else{
                                    PlayerControllView()
                                        .padding()
                                }
                            }
                            
                                .background(
                                    
                                    Rectangle()
                                        .fill(.thinMaterial)
                                    
                                )
                                
                              
                            }
                        .ignoresSafeArea()
                        
                        
    
                       
    
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
