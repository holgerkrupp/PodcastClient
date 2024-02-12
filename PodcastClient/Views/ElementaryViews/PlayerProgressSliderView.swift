//
//  PlayerProgressSliderView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 19.01.24.
//

import SwiftUI

struct PlayerProgressSliderView: View {
    @Binding var value: Double
    
    @State var lastCoordinateValue: CGFloat = 0.0
    var sliderRange: ClosedRange<Double> = 1...100
    var thumbColor: Color = .yellow
    var minTrackColor: Color = .blue
    var maxTrackColor: Color = .gray
    
    var player = Player.shared
    
    var body: some View {
        GeometryReader { gr in
            let thumbHeight = gr.size.height * 1.1
            let thumbWidth = gr.size.width * 0.03
            let radius = gr.size.height * 0.5
            let minValue = gr.size.width * 0.015
            let maxValue = (gr.size.width * 0.98) - thumbWidth
            
            let scaleFactor = (maxValue - minValue) / (sliderRange.upperBound - sliderRange.lowerBound)
            let lower = sliderRange.lowerBound
            let sliderVal = abs((self.value - lower) * scaleFactor + minValue)
            
            ZStack {
                Rectangle()
                    .foregroundColor(.secondary)
                    .frame(width: gr.size.width, height: gr.size.height * 0.95)
                    .clipShape(RoundedRectangle(cornerRadius: radius))
                HStack {
                    Rectangle()
                        .foregroundColor(.accent)
                        .frame(width: sliderVal, height: gr.size.height * 0.95)
                    Spacer()
                }
                .clipShape(RoundedRectangle(cornerRadius: radius))
                /*
                ZStack{
                    if let chapters = player.currentEpisode?.chapters{
                        ForEach (chapters, id:\.self) { chapter in
                            if let start = chapter.start, let duration = player.currentEpisode?.duration{
                                let chapterMark = start/duration
                                Rectangle()
                                    .foregroundColor(.primary)
                                    .frame(width: 1.0, height: gr.size.height * 0.95)
                                    .offset(x: chapterMark)
                            }
                        }
                    }
                }
                */
                HStack {
                    RoundedRectangle(cornerRadius: radius)
                        .foregroundColor(.primary)
                        .frame(width: thumbWidth, height: thumbHeight)
                        .offset(x: sliderVal)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    if (abs(v.translation.width) < 0.1) {
                                        self.lastCoordinateValue = sliderVal
                                    }
                                    if v.translation.width > 0 {
                                        let nextCoordinateValue = min(maxValue, self.lastCoordinateValue + v.translation.width)
                                        
                                        self.value = ((nextCoordinateValue - minValue) / scaleFactor)  + lower
                                    } else {
                                        let nextCoordinateValue = max(minValue, self.lastCoordinateValue + v.translation.width)
                                        self.value = ((nextCoordinateValue - minValue) / scaleFactor) + lower
                                    }
                                }
                        )
                    Spacer()
                }
            }
        }
    }
}
