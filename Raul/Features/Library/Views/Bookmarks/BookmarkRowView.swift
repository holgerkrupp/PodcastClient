//
//  BookmarkRowView.swift
//  Raul
//
//  A bookmark row styled like EpisodeRowView: left-aligned cover art on the
//  shared ESA blurred-row background, with the bookmark's own metadata and
//  playback actions.
//

import SwiftUI
import ESADesignKit

struct BookmarkRowView: View {
    let marker: Bookmark
    let snapshot: BookmarkRowSnapshot
    var isPlaying: Bool
    var clipDisabled: Bool
    var groupPosition: GroupedListRowPosition = .single
    var onPlayToggle: () -> Void
    var onClip: () -> Void
    var onLoad: () -> Void

    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 160
    @ScaledMetric(relativeTo: .body) private var artworkSize: CGFloat = 100

    var body: some View {
        let episode = snapshot.episode
        let rowContent = VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 14) {
                CoverImageView(
                    episode: episode,
                    loadDelay: EpisodeRowArtworkPolicy.foregroundLoadDelay,
                    cornerRadius: GroupedListRowStyle.artworkCornerRadius
                )
                    .frame(width: artworkSize, height: artworkSize)
                    .accessibilityHidden(true)
                
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.podcastTitle ?? snapshot.episodeTitle ?? "")
                        .font(.caption)
                        .esaForeground(.secondary)
                        .lineLimit(1)
                    
                    Text(marker.title)
                        .font(.headline)
                        .lineLimit(2)
                        .esaForeground(.primary)
                    
                    if let start = marker.start {
                        Text("at \(Duration.seconds(start).formatted(.units(width: .abbreviated)))")
                            .font(.caption)
                            .esaForeground(.secondary)
                    }
                    
                    Spacer(minLength: 0)
                    
                    
                }
            }
                .frame(maxWidth: .infinity, minHeight: artworkSize, alignment: .topLeading)
                if episode != nil {
                    HStack(spacing: 10) {
                        Button(action: onPlayToggle) {
                            Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.glass(.clear))
                        Spacer()
                        Button(action: onClip) {
                            Label("Clip", systemImage: "scissors")
                        }
                        .buttonStyle(.glass(.clear))
                        .disabled(clipDisabled)
                        Spacer()
                        Button(action: onLoad) {
                            Label("Load", systemImage: "play.circle")
                        }
                        .buttonStyle(.glass(.clear))
                    }
                }
            
        }
        return rowContent
            .ESA_RowView(image: snapshot.artworkURL, minHeight: rowHeight)
            .clipShape(groupPosition.backgroundShape)
            .contentShape(Rectangle())
    }
}
