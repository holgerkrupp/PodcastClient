//
//  DiscoveredPodcastRowView.swift
//  Raul
//
//  A discovered podcast in a list. Artwork is decorative; VoiceOver announces
//  the title together with the broadcaster and country.
//

import SwiftUI

struct DiscoveredPodcastRowView: View {
    let podcast: DiscoveredPodcast
    /// Shown in cross-provider search, where the source is not obvious from context.
    var showsSource: Bool = false
    var registry: PodcastDiscoveryRegistry = .shared

    @ScaledMetric(relativeTo: .body) private var artworkSize: CGFloat = 56

    private var broadcaster: PublicBroadcaster? {
        registry.broadcaster(withID: podcast.broadcasterID)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImageView(imageURL: podcast.artworkURL)
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(podcast.title)
                    .font(.headline)
                    .lineLimit(2)

                if showsSource, let broadcaster {
                    Text(broadcaster.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(broadcaster.countryName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let author = podcast.author, author.isEmpty == false {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let summary = podcast.summary, summary.isEmpty == false {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [podcast.title]

        if let broadcaster {
            parts.append(broadcaster.name)
            parts.append(broadcaster.countryName)
        } else if let author = podcast.author, author.isEmpty == false {
            parts.append(author)
        }

        return parts.joined(separator: ", ")
    }
}
