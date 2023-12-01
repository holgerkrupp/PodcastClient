//
//  PlayerControls.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import SwiftUI

struct PlayerControlsView: View {
    
    var player = Player.shared
    
    
    
    var body: some View {
                HStack{
            
            Label {
                Text("Maximize")
            } icon: {
                Image(systemName: "chevron.up")
                    .resizable()
                    .scaledToFit()
            }
            .labelStyle(.iconOnly)
            .frame(maxWidth: .infinity)
            
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
            .frame(maxWidth: .infinity)
            
            
        }
    }
}

#Preview {
    PlayerControlsView()
}
