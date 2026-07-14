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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let marker: Bookmark
    var isPlaying: Bool
    var clipDisabled: Bool
    var onPlayToggle: () -> Void
    var onClip: () -> Void
    var onLoad: () -> Void

    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 160
    @ScaledMetric(relativeTo: .body) private var artworkSize: CGFloat = 100

    var body: some View {
        let episode = marker.bookmarkEpisode

        HStack(alignment: .top, spacing: 14) {
            CoverImageView(episode: episode)
                .frame(width: artworkSize, height: artworkSize)
                .cornerRadius(8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(episode?.displayPodcastTitle ?? episode?.title ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)

                Text(marker.title)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)

                if let start = marker.start {
                    Text("at \(Duration.seconds(start).formatted(.units(width: .abbreviated)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if episode != nil {
                    HStack(spacing: dynamicTypeSize.isAccessibilitySize ? 14 : 10) {
                        Button(action: onPlayToggle) {
                            Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.glass(.clear))

                        Button(action: onClip) {
                            Label("Clip", systemImage: "scissors")
                        }
                        .buttonStyle(.glass(.clear))
                        .disabled(clipDisabled)

                        Button(action: onLoad) {
                            Label("Load", systemImage: "play.circle")
                        }
                        .buttonStyle(.glass(.clear))
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: artworkSize, alignment: .topLeading)
        }
        .ESA_RowView(image: episode?.imageURL ?? episode?.podcast?.imageURL, minHeight: rowHeight)
    }
}
