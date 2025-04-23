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


    private var player = Player.shared
    
    @State private var showMiniPlayer = false
    @State private var isScrollingUp = false
    @State private var lastScrollPosition: CGFloat = 0
    @Namespace private var playerNamespace

    var body: some View {
        ZStack(alignment: isScrollingUp ? .bottom : .top) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 16) {
                        // Top items section
                        
                           EpisodeListView(predicate: #Predicate<Episode> { episode in
                                episode.metaData?.lastPlayed != nil
                           }, sort: \.metaData?.lastPlayed, order: .forward)
                         
                       // EpisodeListView()
                        Divider()
                        
                        // Player section
                        
                            playerView(fullSize: true)
                                .id("player")
                                .padding(.horizontal)
                                .onAppear {
                                    // Animate into mini when it's off-screen
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        withAnimation {
                                            proxy.scrollTo("player", anchor: .center)
                                        }
                                    }
                                }
                        
                        
                        // Player position tracker
                        GeometryReader { geo in
                            Color.clear
                                .onChange(of: geo.frame(in: .global)) { oldValue, newValue in
                                    let screenHeight = UIScreen.main.bounds.height
                                    let buffer: CGFloat = 100 // Increased buffer for better timing
                                    
                                    
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
                        .frame(height: 1) // Minimize the GeometryReader's impact
                        
                        Divider()
                        //EpisodeListView()
                        
                        
                        // Bottom items section
                        PlaylistView(playlist: PlaylistManager.shared.playnext, container: modelContext.container)
                  /*
                        EpisodeListView(predicate: #Predicate<Episode> { episode in
                            episode.metaData?.lastPlayed == nil
                        }, sort: \.publishDate, order: .reverse)
                    */
                    }
                    .padding(.vertical)
                }
                .onAppear {
                    DispatchQueue.main.async {
                        proxy.scrollTo("player", anchor: .center)
                    }
                }
            }
            
            if showMiniPlayer {
                playerView(fullSize: false)
                    .padding()
                    .transition(.move(edge: isScrollingUp ? .bottom : .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
    }
    
    @ViewBuilder
    func playerView(fullSize: Bool) -> some View {
        VStack {
            PlayerView(fullSize: fullSize)
                .frame(width: UIScreen.main.bounds.width * 0.9, height: fullSize ? UIScreen.main.bounds.height * 0.5 : 80)
                .matchedGeometryEffect(id: "playerView", in: playerNamespace, isSource: fullSize)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.thinMaterial)
                .shadow(radius: 3)
        )
    }
}



#Preview {
    TimelineView()
}
