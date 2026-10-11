//
//  DiscoveredPodcastRowView.swift
//
//  A compact, value-only row for a podcast found through public broadcaster
//  discovery. Navigation remains the responsibility of the caller.

import SwiftUI

struct DiscoveredPodcastRowView: View {
    let podcast: DiscoveredPodcast
    /// Shown in cross-provider search, where the source is not obvious from context.
    var showsSource: Bool = false
    var registry: PodcastDiscoveryRegistry = .shared

    private var broadcaster: PublicBroadcaster? {
        registry.broadcaster(withID: podcast.broadcasterID)
    }

    var body: some View {
        PodcastRowContentView(
            presentation: presentation,
            density: .compact,
            accessibilityLabel: accessibilityLabel
        )
    }

    private var presentation: PodcastRowPresentation {
        let selectedBroadcaster = showsSource ? broadcaster : nil
        let row = PodcastRowPresentation(
            identity: podcast.feedURL.map(PodcastFeedIdentity.normalizedFeedURLString)
                ?? podcast.deduplicationKey,
            feedURL: podcast.feedURL,
            title: podcast.title,
            author: selectedBroadcaster?.name ?? podcast.author,
            context: selectedBroadcaster?.countryName,
            summary: podcast.summary,
            artworkURL: podcast.artworkURL
        )
        return row
    }

    private var accessibilityLabel: String {
        var parts = [presentation.title]

        if let broadcaster {
            parts.append(broadcaster.name)
            parts.append(broadcaster.countryName)
        } else if let author = presentation.author {
            parts.append(author)
        }

        return parts.joined(separator: ", ")
    }
}
