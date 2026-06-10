//
//  EpisodeProgressView.swift
//  UpNext
//
//  Created by Holger Krupp on 17.05.26.
//

import SwiftUI

struct EpisodeProgressView: View {
    
    @State var episode: Episode
    var body: some View {
        VStack{
            PlayerProgressSliderView(value: $episode.playProgress, markers: $episode.chapters, allowTouch: false, sliderRange: 0...1)
                .frame(height: 30)
            HStack{
                if let remainingTime = episode.remainingTime,remainingTime != episode.duration, remainingTime > 0 {
                    Text(Duration.seconds(episode.remainingTime ?? 0.0).formatted(.units(width: .narrow)) + " remaining")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.primary)
                } else {
                    Text(Duration.seconds(episode.duration ?? 0.0).formatted(.units(width: .narrow)))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.primary)
                }
                Spacer()
                Text((episode.publishDate?.formatted(date: .numeric, time: .shortened) ?? ""))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.primary)
            }
            
        }
    }
}


