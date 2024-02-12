//
//  PlayerControls.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import SwiftUI



struct PlayerControlsView: View {
    
    @Binding var miniPlayerHeight:CGFloat
    
    var maxPlayerHeight:CGFloat 
    var minPlayerHeight:CGFloat
    
  //  @State var player = Player.shared
     var player = Player.shared

    
    var body: some View {

                
                if miniPlayerHeight == maxPlayerHeight{
                    
                    
                    if player.currentEpisode != nil{
                        PlayerView()

                    }else{
                        Text("no podcast loaded")
                    }
                    
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
                        Image(systemName: player.settings.skipBack.backString)
                            .resizable()
                            .scaledToFit()
                    }
                    .labelStyle(.iconOnly)
                    .frame(maxWidth: .infinity)
                }
                
                
                Spacer()
                
                
                   PlayButtonView(player: player)
                    .frame(maxWidth: .infinity)
                
                
                
                Spacer()
                
                
                Button(action:player.skipforward){
                    Label {
                        Text("Skip Forward 45 seconds")
                    } icon: {
                        Image(systemName: player.settings.skipForward.forwardString)
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
