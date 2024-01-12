//
//  PlayerControls.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import SwiftUI

struct PlayerControlsView: View {
    
    @Binding var miniPlayerHeight:CGFloat
    
    var maxPlayerHeight:CGFloat = UIScreen.main.bounds.height - 200
    var minPlayerHeight:CGFloat = 20.0
    
    @State var player = Player.shared
  //  @Environment(Player.self) private var player
    
    
    var body: some View {
        ZStack{
            ProgressView(value: player.progress, total: 1.0)
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .tint(.teal)
                .scaleEffect(x: 1, y: 10, anchor: .center)
              
            HStack(alignment: .bottom){
                
                if miniPlayerHeight == maxPlayerHeight{
                    
                    Button {
                        withAnimation {
                            miniPlayerHeight = minPlayerHeight
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
                    }
                    
                }else{
                    
                    
                    
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
                    }
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
