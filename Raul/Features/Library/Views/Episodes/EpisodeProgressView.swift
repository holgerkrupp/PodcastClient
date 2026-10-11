//
//  EpisodeProgressView.swift
//  UpNext
//
//  Created by Holger Krupp on 17.05.26.
//

import SwiftUI

struct EpisodeProgressView: View {

    @Bindable var episode: Episode
    @Bindable private var player = Player.shared

    private var progress: Double {
        guard let episodeURL = episode.url,
              player.currentEpisodeURL == episodeURL else {
            return episode.displayProgress
        }
        return player.progress
    }

    private var timeSummary: String? {
        if let remainingTime = episode.displayRemainingTime,
           remainingTime != episode.duration,
           remainingTime > 0 {
            return Duration.seconds(remainingTime).formatted(.units(width: .narrow)) + " remaining"
        }

        guard let duration = episode.duration, duration > 0 else { return nil }
        return Duration.seconds(duration).formatted(.units(width: .narrow))
    }

    var body: some View {
        VStack(spacing: 8) {
            PlayerProgressSliderView(
                value: .constant(progress),
                markers: $episode.chapters,
                allowTouch: false,
                chapterTimelineDuration: episode.duration,
                sliderRange: 0...1
            )
                .frame(height: 30)
            HStack {
                if let timeSummary {
                    Text(timeSummary)
                        .font(.caption)
                        .monospacedDigit()
                        .esaForeground(.primary)
                }
                Spacer()
                if let publishDate = episode.publishDate {
                    Text(publishDate.formatted(date: .numeric, time: .shortened))
                        .font(.caption)
                        .monospacedDigit()
                        .esaForeground(.primary)
                }
            }
        }
    }
}
