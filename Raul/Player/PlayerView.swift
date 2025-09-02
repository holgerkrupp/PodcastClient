import SwiftUI
import RichText



struct PlayerView: View {
    @Bindable private var player = Player.shared
    @State private var showTranscripts: Bool = false
    @State private var showFullTranscripts: Bool = false
    @State var showSpeedSetting:Bool = false
    @State private var showClipExport = false



    let fullSize: Bool

    var body: some View {
            
            
                if let episode = player.currentEpisode {
                    GeometryReader { geometry in
                        ZStack{
                            
                            // Background layer
                            
                            
                            
                            CoverImageView(episode: episode)
                               
                              
                                .aspectRatio(1, contentMode: .fill)
                                .scaledToFill()
                               
                                .frame(width: geometry.size.width, height: (fullSize && player.currentEpisode != nil) ? geometry.size.height : 80)
                                .ignoresSafeArea(.all, edges: .bottom)
                           
                            
                            Group{
                                if fullSize == true {
                                    VStack{
                                
                                    ScrollView([.vertical]){
                                  //      Spacer(minLength: 20)
                                        PlayerControllView()
                                            .padding()
         
                                        
                                        HStack{
                                          
                                            if let episodeLink = episode.link {

                                                
                                                Link(destination: episodeLink) {
                                                    Label("Open in Browser", systemImage: "safari")
                                                }
                                                .buttonStyle(.glass)
                                             //   .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 8.0))
                                            }
                                            Spacer()
                                           
                                            Button(action: {
                                                showClipExport = true
                                            }) {
                                                Image(systemName: "scissors")
                                            }
                                            .buttonStyle(.glass)
                                            .frame(height: 30)
                                            .help("Share audio clip")
                                            .sheet(isPresented: $showClipExport) {
                                                // TODO: coverImage loading should ideally not be async in the sheet
                                                
                                                if let episode = player.currentEpisode, let audioURL = episode.localFile ?? episode.url {
                                                    AudioClipExportView(
                                                        audioURL: audioURL,
                                                        coverImageURL: episode.imageURL,
                                                        fallbackCoverImageURL: episode.podcast?.imageURL,
                                                        playPosition: player.playPosition,
                                                        duration: episode.duration ?? 60
                                                    )
                                                } else {
                                                    EmptyView()
                                                }
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
                                                .buttonStyle(.glass)

                                            }
                                            
                                         
                                        }
                                        .padding()
                                        
                                        RichText(html: episode.content ?? episode.desc ?? "")
                                            .linkColor(light: Color.secondary, dark: Color.secondary)
                                            .backgroundColor(.transparent)
                                            .padding()
                                            
                                          
                                        
                                    }
                                }
                                    .padding(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
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
