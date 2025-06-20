//
//  TimeLineView.swift
//  Raul
//
//  Created by Holger Krupp on 11.04.25.
//

import SwiftUI
import SwiftData

struct TimelineView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.editMode) private var editMode


    private var player = Player.shared
    
    @State private var showMiniPlayer = false
    @State private var isScrollingUp = false
    @State private var lastScrollPosition: CGFloat = 0
    @State private var scrollToID: String? = nil

    @Namespace private var playerNamespace
    private let twoWeeksAgo = Calendar.current.date(byAdding: .day, value: -14, to: Date())!

    var body: some View {
        NavigationView{

            ZStack(alignment: isScrollingUp ? .bottom : .top) {
                ScrollViewReader { proxy in
                    List{
                        Section{
                            EpisodeListView(predicate: #Predicate<Episode> { episode in
                                episode.metaData?.isHistory == true
                                //&& episode.metaData?.lastPlayed != nil &&
                                //episode.metaData!.lastPlayed! >= twoWeeksAgo
                            }, sort: \.metaData?.lastPlayed, order: .forward)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                           
                        }
                        Section{
                            HStack {
                                Spacer()
                                Image(systemName: "arrowtriangle.up.fill")
                                    .symbolRenderingMode(.monochrome)
                                Image(systemName: "arrowtriangle.up.fill")
                                    .symbolRenderingMode(.monochrome)
                                Image(systemName: "arrowtriangle.up.fill")
                                    .symbolRenderingMode(.monochrome)
                                Text("Recently played")
                                Image(systemName: "arrowtriangle.up.fill")
                                    .symbolRenderingMode(.monochrome)
                                Image(systemName: "arrowtriangle.up.fill")
                                    .symbolRenderingMode(.monochrome)
                                Image(systemName: "arrowtriangle.up.fill")
                                    .symbolRenderingMode(.monochrome)
                                Spacer()
                            }
                            .foregroundStyle(Color(.tertiaryLabel))
                            .font(.caption)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            
                        }
                        Section {
                         
                                playerView(fullSize: true)
                                    .id("player")
                                    .padding(.horizontal)

                                
                                
                                    .background(
                                        GeometryReader { geo in
                                            Color.clear
                                                .onChange(of: geo.frame(in: .global)) { oldValue, newValue in
                                                    let screenHeight = UIScreen.main.bounds.height
                                                    let buffer: CGFloat = 0 // Increased buffer for better timing
                                                    
                                                    
                                                    isScrollingUp = newValue.minY > oldValue.minY
                                                    
                                                    let position = isScrollingUp ? newValue.minY : newValue.maxY
                                                    let isVisible = position > buffer && position < (screenHeight - buffer)
                                                    
                                                    // Detect scroll direction
                                                    
                                                    lastScrollPosition = position
                                                    
                                                    // Add a small delay to prevent flickering
                                                    if showMiniPlayer != !isVisible {
                                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                                            withAnimation(.spring()) {
                                                                showMiniPlayer = !isVisible
                                                            }
                                                        }
                                                    }
                                                }
                                        }
                                        
                                    )
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                
                            
                        }
                        Section {
                            
                            HStack {
                                Spacer()
                                Image(systemName: "arrowtriangle.down.fill")
                                    .symbolRenderingMode(.monochrome)
                                Image(systemName: "arrowtriangle.down.fill")
                                    .symbolRenderingMode(.monochrome)
                                Image(systemName: "arrowtriangle.down.fill")
                                    .symbolRenderingMode(.monochrome)
                                Text("Up next")
                                Image(systemName: "arrowtriangle.down.fill")
                                    .symbolRenderingMode(.monochrome)
                                Image(systemName: "arrowtriangle.down.fill")
                                    .symbolRenderingMode(.monochrome)
                                Image(systemName: "arrowtriangle.down.fill")
                                    .symbolRenderingMode(.monochrome)
                                Spacer()
                            }
                            .foregroundStyle(Color(.tertiaryLabel))
                            .font(.caption)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            
                        }
                        
                        
                        Section{
                            PlaylistView()
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                        
                    }
                    .listStyle(PlainListStyle())
                    .padding(.top, 0) 
                    
                    

                    .onChange(of: scrollToID) {
                        if let target = scrollToID {
                            withAnimation {
                                proxy.scrollTo(target, anchor: .top)
                            }
                            scrollToID = nil
                        }
                    }
                }
                

            }
            .onAppear {
                self.scrollToID = "player"
            }
            
        }
        .onAppear {
            Task{
                await DownloadManager.shared.refreshDownloadedFiles()
            }
        }
        
    }
    
    @ViewBuilder
    func playerView(fullSize: Bool) -> some View {
        
        if let episode = player.currentEpisode {
            
            if fullSize {
                NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                  
                        PlayerView(fullSize: fullSize)
                            .matchedGeometryEffect(id: "playerView", in: playerNamespace, isSource: fullSize)
                    
                }
            }else{
                PlayerView(fullSize: fullSize)
                    .matchedGeometryEffect(id: "playerView", in: playerNamespace, isSource: fullSize)
            }
            

        }else{
          
            PlayerEmptyView()
                .matchedGeometryEffect(id: "playerView", in: playerNamespace, isSource: fullSize)
            
        }



    }
}



#Preview {
    TimelineView()
}
