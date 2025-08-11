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
    
    @State private var fakeProgress : Double?

    
    init(fakeProgress : Double? = nil){
        self.fakeProgress = fakeProgress
    }
    
    var body: some View {
        if let episode = player.currentEpisode{
        GeometryReader { geo in
            
            ZStack{
                
                // Background layer
                HStack{
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.2))
                        .frame(width: geo.size.width * (fakeProgress ?? player.progress))
                    Spacer()
                }
                
                if placement == .inline {
                    HStack{
                        
                        
                        CoverImageView(episode: episode, timecode: player.playPosition)
                            .frame(width: geo.size.height * 0.75, height: geo.size.height * 0.75)
                            .scaledToFit()
                            .clipShape(Circle())
                            .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0))
                        
                        
                        
                        VStack(alignment: .leading){
                            Text("\(player.currentEpisode?.podcast?.title ?? "here be podcast title")")
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundColor(.secondary)
                            Text("\(player.currentEpisode?.title ?? "this could be an episode title")")
                                .font(.caption)
                                .foregroundColor(.primary)

                                .lineLimit(1)
                            
                        }
                        
                        //    .padding()
                        Spacer()
                        Group{

                            
                            
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
                            .padding(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 12))
                            
                            

                            
                        }
                        
                        .frame(height: geo.size.height * 0.6)
                        
                    }
                }else{
                 
                    HStack{
                        
                        
                        CoverImageView(episode: episode, timecode: player.playPosition)
                            .frame(width: geo.size.height * 0.75, height: geo.size.height * 0.75)
                            .scaledToFit()
                            .clipShape(Circle())
                            .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0))
                        
                        
                        
                        VStack(alignment: .leading){
                            Text("\(player.currentEpisode?.podcast?.title ?? "here be podcast title")")
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundColor(.secondary)
                            Text("\(player.currentEpisode?.title ?? "this could be an episode title")")
                                .font(.caption)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            
                        }
                        
                        //    .padding()
                        Spacer()
                        Group{

                            
                            
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
                            .padding(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 12))
                            
                            

                            
                        }
                        
                        .frame(height: geo.size.height * 0.6)
                        
                    }
                    
                }
                
            }
            .tint(Color.accentColor)
            
            .onTapGesture {
                presentingModal = true
            }
        }
        .id(episode.id)
        .sheet(isPresented: $presentingModal, content: {
            
                PlayerView(fullSize: true)
                .presentationDragIndicator(.visible)
                .padding(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))

            
        })
        }
           
            

    }
}
#Preview {
        TabView {
            List{
                ForEach(1...100, id : \.self){_ in
                    Text("Hello World")
                }
            }
            
    }.tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            
     
            PlayerTabBarView(fakeProgress: 0.5)
           
        }
       
    
}

