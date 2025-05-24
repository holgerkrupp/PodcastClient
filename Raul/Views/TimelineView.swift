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
    @Namespace private var playerNamespace
    private let twoWeeksAgo = Calendar.current.date(byAdding: .day, value: -14, to: Date())!

    var body: some View {
        NavigationView{
            ZStack(alignment: isScrollingUp ? .bottom : .top) {
                ScrollViewReader { proxy in
                    List {
                        //ScrollView(.vertical) {
                        //LazyVStack(spacing: 16) {
                        
                        Section{
                            EpisodeListView(predicate: #Predicate<Episode> { episode in
                                episode.metaData?.isHistory == true
                                //&& episode.metaData?.lastPlayed != nil &&
                                //episode.metaData!.lastPlayed! >= twoWeeksAgo
                            }, sort: \.metaData?.lastPlayed, order: .forward)
                            .listRowSeparator(.hidden)
                            //}
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
                            
                        }
                        Section {
                            playerView(fullSize: true)
                                .id("player")
                                .padding(.horizontal)
                            /*
                             .onAppear {
                             DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                             withAnimation {
                             proxy.scrollTo("player", anchor: .center)
                             }
                             }
                             }
                             */
                            
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
                            
                        }
                        
                        
                        Section{
                            PlaylistView()
                                .listRowSeparator(.hidden)
                        }
                        
                    }
                    .listStyle(PlainListStyle())
                    .padding(.top, 0) // Optionally reduce padding to make it look cleaner
                    
                    .environment(\.editMode, .constant(.active))  // Force edit mode active for the entire List
                    
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            EditButton()
                        }
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
    }
    
    @ViewBuilder
    func playerView(fullSize: Bool) -> some View {
        VStack {
            PlayerView(fullSize: fullSize)
              //  .frame(width: UIScreen.main.bounds.width * 0.9, height: fullSize ? UIScreen.main.bounds.height * 0.5 : 80)
                .matchedGeometryEffect(id: "playerView", in: playerNamespace, isSource: fullSize)
        }

    }
}



#Preview {
    TimelineView()
}
