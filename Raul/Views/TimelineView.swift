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
    @Query(filter: #Predicate<Episode> { $0.metaData?.lastPlayed != nil }, sort: \.metaData?.lastPlayed, order: .forward) var topItems: [Episode]
    @Query(filter: #Predicate<Episode> { $0.metaData?.lastPlayed == nil }, sort: \.publishDate, order: .reverse) var bottomItems: [Episode]
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
                        ForEach(topItems) { item in
                            if item.id != player.currentEpisode?.id {
                                EpisodeRowView(episode: item)
                                    .id(item.id)
                                    .padding(.horizontal)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color(.systemGray6))
                                            .shadow(radius: 2)
                                    )
                            }
                        }
                        
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
                                .onChange(of: geo.frame(in: .global).minY) { oldValue, newValue in
                                    let screenHeight = UIScreen.main.bounds.height
                                    let buffer: CGFloat = 100 // Increased buffer for better timing
                                    let isVisible = newValue > buffer && newValue < (screenHeight - buffer)
                                    
                                    // Detect scroll direction
                                    isScrollingUp = newValue > oldValue
                                    lastScrollPosition = newValue
                                    
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
                        
                        // Bottom items section
                        ForEach(bottomItems) { item in
                            EpisodeRowView(episode: item)
                                .id(item.id)
                                .padding(.horizontal)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(.systemGray6))
                                        .shadow(radius: 2)
                                )
                        }
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
                .frame(height: fullSize ? UIScreen.main.bounds.height * 0.5 : 80)
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
