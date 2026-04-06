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
                                    GeometryReader { geo in
                                        let preferWideLayout = geo.size.width > geo.size.height

                                        VStack {
                                            ScrollView([.vertical]) {
                                                PlayerControllView(preferWideLayout: preferWideLayout)
                                                    .padding()

                                                RichText(html: episode.content ?? episode.desc ?? "")
                                                    .linkColor(light: Color.secondary, dark: Color.secondary)
                                                    .backgroundColor(.transparent)
                                                    .padding()
                                            }
                                        }
                                    }
                                    .padding(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                }else{
                                    PlayerControllView()
                                        .padding()
                                }
                            }
                            
                                .background(
                                    
                                    CoverImageView(episode: episode)
                                        .aspectRatio(1, contentMode: .fill)
                                        .scaledToFill()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity) // Ensure it takes up all available space
                                                        .ignoresSafeArea(.all) // Crucial: extends the image behind safe areas (like under the status bar)
                                                        
                                        .blur(radius: 20)
                                        .opacity(0.5)
                                      
                                    
                                )
                                
                              
                            
                        .safeAreaPadding(.top, 8)
                        
                        
    
                       
    
                    
                    

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
