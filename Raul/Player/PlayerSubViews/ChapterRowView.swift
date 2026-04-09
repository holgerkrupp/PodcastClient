//
//  ChapterRowView.swift
//  Raul
//
//  Created by Holger Krupp on 19.05.25.
//

import SwiftUI

struct ChapterRowView: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Bindable var chapter: Marker
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

                    if differentiateWithoutColor {
                        if player.currentChapter == chapter {
                            Label("Current chapter", systemImage: "speaker.wave.2.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        } else if chapter.shouldPlay == false {
                            Label("Will be skipped", systemImage: "forward.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text(Duration.seconds(chapter.duration ?? 0.0).formatted(.units(width: .narrow)))
                            .font(.footnote)
                            .monospacedDigit()
                        
                        Spacer()
                        
                        if let url = chapter.link {
                            Link(destination: url) {
                                Image(systemName: "link")
                                    .foregroundStyle(.accent)
                            }
                            .padding(.trailing, 8)
                            .accessibilityLabel("Open chapter link")
                            .accessibilityHint("Opens the chapter webpage in Safari")
                            .accessibilityInputLabels([Text("Open chapter link"), Text("Chapter link")])
                        }
                    }
                    HStack {
                        Text(Duration.seconds(chapter.start ?? 0.0).formatted(.units(width: .narrow)))
                       
                        Text(" - ")
                        Text(Duration.seconds(chapter.end ?? 0.0).formatted(.units(width: .narrow)))
                            
                    }
                        .font(.footnote)
                        .monospacedDigit()
                   
                }
                Toggle("Play Chapter", isOn: Binding(
                    get: { chapter.shouldPlay },
                    set: { newValue in
                        chapter.shouldPlay = newValue
                        
                    }
                ))
                .toggleStyle(SkipChapter())
                .accessibilityLabel("Play chapter")
                .accessibilityHint("Turn off to skip this chapter automatically")
                .accessibilityInputLabels([Text("Play chapter"), Text("Skip chapter")])
                
            }
            .padding(.horizontal)
            .onTapGesture {
                Task{
                    await player.skipTo(chapter: chapter)
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Double tap to jump playback to this chapter")
            .accessibilityInputLabels([Text("Play chapter \(chapter.title)"), Text("Jump to chapter \(chapter.title)")])
            .accessibilityLabel("Chapter \(chapter.title)")
            .accessibilityValue(chapter.shouldPlay ? "Enabled" : "Skipped")
            .accessibilityAction {
                Task {
                    await player.skipTo(chapter: chapter)
                }
            }
            .foregroundStyle(
                chapter.shouldPlay == false ? Color.secondary : player.currentChapter == chapter ? Color.accent : Color.primary
            )
        
    }
}
