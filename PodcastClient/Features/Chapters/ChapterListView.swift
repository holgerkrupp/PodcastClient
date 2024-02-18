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
    
    var chaptersByType: [ChapterType: [Chapter]] {
        Dictionary(grouping: chapters, by: { $0.type })
    }
    
    @State private var selectedType: ChapterType?


    
    var body: some View {
        ScrollView{
       /*
            Picker("Select Chapter Type", selection: $selectedType) {
                ForEach(chaptersByType.keys.sorted(), id: \.self) { type in
                    Text(type.desc).tag(type)
                }
            }
            .pickerStyle(.inline)
            
            ForEach($chapters.sorted(by: {$0.start.wrappedValue ?? 0 < $1.start.wrappedValue ?? 1}).filter({$0.type.wrappedValue == selectedType ?? ChapterType.embedded})){ chapter in
            */
                ForEach($chapters.sorted(by: {$0.start.wrappedValue ?? 0 < $1.start.wrappedValue ?? 1})){ chapter in

                    
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
