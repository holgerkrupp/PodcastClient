//
//  PlayerTabBarView.swift
//  Raul
//
//  Created by Holger Krupp on 10.06.25.
//

import SwiftUI

@available(iOS 26.0, *)
struct PlayerTabBarView: View {

    @Bindable private var player = Player.shared
    
    
    
    // The following is, because iOS26 Beta 5 (maybe following as well) don't propperly change the text color and often it's not readable.
    /*
    @Environment(\.colorScheme) var colorScheme
    private var dynamicPrimaryColor: Color {
        colorScheme == .dark ? Color.white : Color.black
    }
    private var dynamicSecondaryColor: Color {
        colorScheme == .dark ? Color(white: 0.7) : Color(white: 0.3)
    }
*/
    var body: some View {
        if let episode = player.currentEpisode {
            let podcastTitle = episode.displayPodcastTitle ?? "Podcast"

            ZStack(alignment: .leading) {
                MiniPlayerProgressBackground()

                HStack(spacing: 10) {
                    CoverImageView(episode: episode)
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(podcastTitle)
                            .font(.caption2)
                            .lineLimit(1)
                        //    .foregroundColor(dynamicSecondaryColor)
                        Text(episode.title)
                            .font(.caption)
                            .lineLimit(1)
                         //   .foregroundColor(dynamicPrimaryColor)
                    }

                    Spacer(minLength: 8)

                    Button(action: {
                        if player.isPlaying {
                            player.pause()
                        } else {
                            player.play()
                        }
                    }) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.headline)
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel(player.isPlaying ? "Pause playback" : "Start playback")
                    .accessibilityHint(player.isPlaying ? "Pauses the current episode" : "Starts playback of the current episode")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .contentShape(Rectangle())
            .transaction { transaction in
                transaction.animation = nil
            }
         //   .tint(dynamicPrimaryColor)
            .accessibilityLabel("Mini player, \(episode.title)")
            .accessibilityHint("Double tap anywhere on the mini player to open full player controls")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("Open full player")) {
                player.isPlayerSheetPresented = true
            }
            .onTapGesture {
                player.isPlayerSheetPresented = true
            }
        }
    }
}

@available(iOS 26.0, *)
private struct MiniPlayerProgressBackground: View {
    @Bindable private var player = Player.shared
    @State private var displayedProgress: Double = 0.0

    private let progressStep: Double = 0.005

    var body: some View {
        Rectangle()
            .fill(Color.accent.opacity(0.2))
            .scaleEffect(x: displayedProgress, y: 1, anchor: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .transaction { transaction in
                transaction.animation = nil
            }
            .onAppear {
                refreshDisplayedProgress(force: true)
            }
            .onChange(of: player.currentEpisodeURL) { _, _ in
                refreshDisplayedProgress(force: true)
            }
            .onChange(of: player.currentEpisode?.duration) { _, _ in
                refreshDisplayedProgress(force: true)
            }
            .onChange(of: player.playPosition) { _, _ in
                refreshDisplayedProgress()
            }
    }

    private func quantizedProgress(from rawProgress: Double) -> Double {
        let clamped = min(1.0, max(0.0, rawProgress))
        return (clamped / progressStep).rounded() * progressStep
    }

    private func refreshDisplayedProgress(force: Bool = false) {
        let quantized = quantizedProgress(from: player.progress)
        if force || quantized != displayedProgress {
            displayedProgress = quantized
        }
    }
}

#Preview {
        TabView {
            List{
                ForEach(1...100, id : \.self){_ in
                    Text("Hello World")
                }
            }
            
    }.tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            
     
            PlayerTabBarView()
           
        }
       
    
}
