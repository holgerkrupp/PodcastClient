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
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(width: geo.size.width * (Player.shared.currentEpisode?.maxPlayProgress ?? 0.0))
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
                            
                            Text("\(player.currentEpisode?.title ?? "")")
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .minimumScaleFactor(0.75)
                                .frame(maxWidth: geo.size.width/3*2)
                                .padding()
                            
                            //   Spacer()
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
                            .padding(10)
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
    if #available(iOS 26.0, *) {
        PlayerTabBarView()
    } else {
        // Fallback on earlier versions
    }
}

