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
 
    @Bindable private var player = Player.shared
    
    var body: some View {
        GeometryReader { geo in
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
                    
                    Text("\(player.currentEpisode?.title ?? "")")
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: geo.size.width/3*2)
                      
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
                      
                    }
                    .padding()
                }
        
                
            }
        }
    }
}
#Preview {
    if #available(iOS 26.0, *) {
        PlayerTabBarView()
    } else {
        // Fallback on earlier versions
    }
}

