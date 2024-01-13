//
//  PlayerControls.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import SwiftUI

struct PlayerControlsView: View {
    
    @Binding var miniPlayerHeight:CGFloat
    
    var maxPlayerHeight:CGFloat = UIScreen.main.bounds.height - 150
    var minPlayerHeight:CGFloat = 20.0
    
  //  @State var player = Player.shared
    @Environment(Player.self) private var player
    
    
    var body: some View {

                
                if miniPlayerHeight == maxPlayerHeight{
                    
                    PlayerView()
                    
                }else{
                    ZStack{
                        ProgressView(value: player.progress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .tint(.teal)
                            .scaleEffect(x: 1, y: 10, anchor: .center)
                        
                        HStack(alignment: .bottom){
                    
                    
                    Button {
                        withAnimation {
                            miniPlayerHeight = maxPlayerHeight
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
             
                
                
                
                Spacer()
                
                
                Button(action:player.skipback){
                    Label {
                        Text("Skip Back 45 seconds")
                    } icon: {
                        Image(systemName: "gobackward.45")
                            .resizable()
                            .scaledToFit()
                    }
                    .labelStyle(.iconOnly)
                    .frame(maxWidth: .infinity)
                }
                
                
                Spacer()
                
                
                Button(action:player.playPause){
                    Label {
                        Text("Play")
                    } icon: {
                        player.playPauseButton
                            .scaledToFit()
                    }
                    .labelStyle(.iconOnly)
                    .frame(maxWidth: .infinity)
                }
                
                Spacer()
                
                
                Button(action:player.skipforward){
                    Label {
                        Text("Skip Forward 45 seconds")
                    } icon: {
                        Image(systemName: "goforward.45")
                            .resizable()
                            .scaledToFit()
                    }
                    .labelStyle(.iconOnly)
                    .frame(maxWidth: .infinity)
                }
                
                Spacer()
                
                Button {
                    withAnimation {
                        miniPlayerHeight = maxPlayerHeight
                    }
                } label: {
                    Label {
                        Text("Show Details")
                    } icon: {
                        player.coverImage
                            .scaledToFit()
                    }
                    .labelStyle(.iconOnly)
                    .frame(maxWidth: .infinity)
                }
                        }
                        
                
            }.frame(maxWidth: .infinity, maxHeight: 30)
        }


        
    }
    

    
}



/*
#Preview {
 PlayerControlsView(miniplayerHeight: Binding(20.0))
}
*/
