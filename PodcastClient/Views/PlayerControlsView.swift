//
//  PlayerControls.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import SwiftUI

struct PlayerControlsView: View {
    
    @Binding var miniplayerHeight:CGFloat
    
    var maxPlayerHeight:CGFloat = UIScreen.main.bounds.height - 500
    var minPlayerHeight:CGFloat = 20.0
    
    @State var player = Player.shared
    
    
    
    var body: some View {
        
        Text(player.currentEpisode?.title ?? "Here be Mini Player")
            .font(.caption)
        
        HStack(alignment: .bottom){
           
            if miniplayerHeight == maxPlayerHeight{
               
                    Button {
                        withAnimation {
                            miniplayerHeight = minPlayerHeight
                        }
                    } label: {
                        Label {
                            Text("Minimize")
                        } icon: {
                            Image(systemName: "chevron.down")
                                .resizable()
                                .scaledToFit()
                        }
                        .labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity)
                    }
                
                }else{
                    
                    
                    
                    Button {
                        withAnimation {
                            miniplayerHeight = maxPlayerHeight
                        }
                    } label: {
                        Label {
                            Text("Maximize")
                        } icon: {
                            Image(systemName: "chevron.up")
                                .resizable()
                                .scaledToFit()
                        }
                        .labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity)
                    }
                }
            
            
            
            
            
            
            Button(action:player.skipback){
                Label {
                    Text("Skip Back")
                } icon: {
                    Image(systemName: "gobackward.45")
                        .resizable()
                        .scaledToFit()
                }
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity)
            }
            
            
            
            
            Button(action:player.playPause){
                Label {
                    Text("Play")
                } icon: {
                    Image(systemName:  "play.fill")
                        .resizable()
                        .scaledToFit()
                }
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity)
            }
            
            
            
            Button(action:player.skipforward){
                Label {
                    Text("Skip Forward")
                } icon: {
                    Image(systemName: "goforward.45")
                        .resizable()
                        .scaledToFit()
                }
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity)
            }
            Label {
                Text("Show Details")
            } icon: {
                Image(systemName: "opticaldisc")
                    .resizable()
                    .scaledToFit()
            }
            .labelStyle(.iconOnly)
            
            
            
        }.frame(maxWidth: .infinity, maxHeight: minPlayerHeight)
    }
    

    
}



/*
#Preview {
 PlayerControlsView(miniplayerHeight: Binding(20.0))
}
*/
