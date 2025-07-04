//
//  PlayerTabBarView.swift
//  Raul
//
//  Created by Holger Krupp on 10.06.25.
//

import SwiftUI

@available(iOS 26.0, *)
struct PlayerTabBarView: View {
    
    @Environment(\.tabViewBottomAccessoryPlacement) var placement
 
    @State private var presentingModal : Bool = false

    @Bindable private var player = Player.shared

    
    var body: some View {
        GeometryReader { geo in
      
                ZStack{
                    
                    // Background layer
                    HStack{
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(width: geo.size.width * (player.progress))
                        Spacer()
                    }
                    if placement == .inline {
                        Button(action: {
                            if player.isPlaying {
                                player.pause()
                            } else {
                                player.play()
                            }
                        }) {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .resizable()
                                .scaledToFit()
                        }
                        .buttonStyle(.borderless)
                    }else{
                        
                        HStack{
                        
                            if let episode = player.currentEpisode{
                                EpisodeCoverView(episode: episode)
                                    .frame(width: geo.size.height * 0.75, height: geo.size.height * 0.75)
                                    .scaledToFit()
                                    .clipShape(Circle())
                                    .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0))
                                
                                    
                            }else{
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(width: geo.size.height * 0.75, height: geo.size.height * 0.75)
                                    .scaledToFit()
                                    .clipShape(Circle())
                                    .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0))
                            }
                            
                            
                            VStack(alignment: .leading){
                                Text("\(player.currentEpisode?.podcast?.title ?? "here be podcast title")")
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                                Text("\(player.currentEpisode?.title ?? "this could be an episode title")")
                                    .font(.caption)
                                    .lineLimit(1)
                                   
                            }
                            
                        //    .padding()
                               Spacer()
                            Group{
                                Button(action:player.skipback){
                                    Label {
                                        Text("Skip Back")
                                    } icon: {
                                        Image(systemName: "15.arrow.trianglehead.counterclockwise")
                                            .resizable()
                                            .scaledToFit()
                                        
                                    }
                                    .labelStyle(.iconOnly)
                                    
                                }
                                .buttonStyle(.borderless)
                                .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0))

                                
                                Button(action: {
                                    if player.isPlaying {
                                        player.pause()
                                    } else {
                                        player.play()
                                    }
                                }) {
                                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                        .resizable()
                                        .scaledToFit()
                                }
                                .buttonStyle(.borderless)
                                .padding(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 2))
                                
                                
                                Button(action:player.skipforward){
                                    Label {
                                        Text("Skip Back")
                                    } icon: {
                                        Image(systemName: "30.arrow.trianglehead.clockwise")
                                            .resizable()
                                            .scaledToFit()
                                        
                                    }
                                    .labelStyle(.iconOnly)
                                    
                                }
                                .buttonStyle(.borderless)
                                .padding(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
                                
                            }
                          
                            .frame(height: geo.size.height * 0.6)
                            
                        }
                      
                        
                        
                    }
                }
                .onTapGesture {
                    presentingModal = true
                }
            }
        .sheet(isPresented: $presentingModal, content: {
            
                PlayerView(fullSize: true)
            
        })
    }
}
#Preview {
        TabView {
            Text("First")
            
    }.tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            
     
                PlayerTabBarView()
           
        }
       
    
}

