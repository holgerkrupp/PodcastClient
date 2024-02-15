//
//  SkipAndBookMarkControllView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 14.02.24.
//

import SwiftUI

struct SkipAndBookmarkListView: View {
    
    @State var events: [Event]
    
    var body: some View {
        List{
            ForEach(events){ event in
                ZStack(alignment: Alignment(horizontal: .center, vertical: .center)) {
                   
                    if event.direction == .back{
                        Image(systemName: "chevron.backward.2")
                            .resizable()
                            .frame(width: 80, height: 80)
                            .foregroundColor(.gray.opacity(0.2))
                            
                    }else{
                        Image(systemName: "chevron.forward.2")
                            .resizable()
                            .frame(width: 80, height: 80)
                            .foregroundColor(.gray.opacity(0.2))
                    }
                    
                    
                    HStack{
                        VStack{
                            Text(event.start?.secondsToHoursMinutesSeconds ?? "")
                                .monospacedDigit()
                            
                            if event.type == .skip{
                                Text(event.end?.secondsToHoursMinutesSeconds ?? "")
                                    .monospacedDigit()
                                
                                Image(systemName: event.directionImage)
                                
                            }
                            
                            
                        }
                        
                        Spacer()
                        VStack{
                            Text(event.date.formatted())
                                .foregroundStyle(.secondary)
                            Text(event.description)
                        }
                        Spacer()
                        Button {
                            if let start = event.start, let episode = event.episode{
                                episode.playPosition = start
                                Player.shared.setCurrentEpisode(episode: episode, playDirectly: true)
                                
                            }
                            
                        }
                    label: {
                        Label {
                            Text("Jump back")
                        } icon: {
                            Image(systemName: "memories")
                        }
                        .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                        
                        
                    }
                }
                
                .swipeActions(edge: .trailing){
                    Button(role: .destructive) {
                        withAnimation {
                            events.removeAll(where: { thisitem in
                                thisitem == event
                            })
                        }
                        
                    } label: {
                        if event.type == .skip{
                            Label("Remove from list", systemImage: "memories.badge.minus")
                        }else{
                            Label("Remove from list", systemImage: "bookmark.slash")
                        }
                    }
                }
            }
        }
    }
}
