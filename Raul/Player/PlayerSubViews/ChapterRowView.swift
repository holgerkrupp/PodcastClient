//
//  ChapterRowView.swift
//  Raul
//
//  Created by Holger Krupp on 19.05.25.
//

import SwiftUI

struct ChapterRowView: View {
    @State var chapter: Chapter
    var player = Player.shared
    var body: some View {
        HStack {
            if let imagedata = chapter.imageData {
                ImageWithData(imagedata)
                    
                    .frame(width: 44, height: 44)
            }
            
            VStack(alignment: .leading) {
                Text(chapter.title)
                    .font(.title3)
                HStack {
                    Text(Duration.seconds(chapter.duration ?? 0.0).formatted(.units(width: .narrow)))
                        .font(.footnote)
                        .monospacedDigit()
                    
                    Spacer()
                    
                    if let url = chapter.link {
                        Link(destination: url) {
                            Image(systemName: "link")
                                .foregroundColor(.blue)
                        }
                        .padding(.trailing, 8)
                    }
                }
            }
            Toggle("Play Chapter", isOn: Binding(
                get: { chapter.shouldPlay },
                set: { newValue in
                        chapter.shouldPlay = newValue
                    
                }
            ))
            .toggleStyle(SkipChapter())
       
    }
    .padding(.horizontal)
    .onTapGesture {
        Task{
            await player.skipTo(chapter: chapter)
        }
    }
    .foregroundStyle(
        chapter.shouldPlay == false ? Color.secondary : player.currentChapter == chapter ? Color.accentColor : Color.primary
    )
    }
}
