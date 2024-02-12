//
//  ChapterListView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 23.01.24.
//

import SwiftUI

struct ChapterListView: View {
    var player = Player.shared
    @State var chapters: [Chapter]
    var body: some View {
        ScrollView{
            ForEach($chapters.sorted(by: {$0.start.wrappedValue ?? 0 < $1.start.wrappedValue ?? 1})){ chapter in
          
                    Text(chapter.wrappedValue.type.rawValue).foregroundStyle(.secondary)
                    
                    HStack(alignment: .center){
                        Button {
                            player.skipTo(chapter: chapter.wrappedValue)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .padding()
                        
                        Spacer()
                    
                        Text(chapter.wrappedValue.title)
                               
                        Spacer()
                        VStack{
                            Toggle("Play Chapter", isOn: chapter.shouldPlay)
                                .toggleStyle(SkipChapter())
                            Text(chapter.wrappedValue.duration?.secondsToHoursMinutesSeconds ?? "")
                                .font(.footnote)
                                .monospacedDigit()
                        }
                        
                    }
                    .onTapGesture {
                        player.skipTo(chapter: chapter.wrappedValue)
                    }
                    .foregroundStyle(
                        chapter.shouldPlay.wrappedValue == false ? Color.secondary : Color.primary
                    )
                    
                   // Text(chapter.wrappedValue.duration?.secondsToHoursMinutesSeconds ?? "")
                
                
                .padding()
                
                if chapter.id != chapters.last?.id {
                    Divider()
                }
            }
            
        }
    }
}
