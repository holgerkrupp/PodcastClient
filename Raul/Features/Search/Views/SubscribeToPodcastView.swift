//
//  SubscribeToPodcastView.swift
//  Raul
//
//  Created by Holger Krupp on 03.04.25.
//

import SwiftUI
import SwiftData

struct SubscribeToPodcastView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var allPodcasts: [Podcast]
    @Bindable var newPodcastFeed: PodcastFeed
    private let previewPodcast: Podcast

    init(newPodcastFeed: PodcastFeed) {
        self.newPodcastFeed = newPodcastFeed
        let previewPodcast = Podcast(from: newPodcastFeed)
        previewPodcast.metaData?.isSubscribed = false
        previewPodcast.metaData?.subscriptionDate = nil
        self.previewPodcast = previewPodcast
        _allPodcasts = Query()
    }

    private var existingPodcast: Podcast? {
        guard let url = newPodcastFeed.url else { return nil }
        return allPodcasts.first(where: { $0.feed == url })
    }

    private var displayedPodcast: Podcast {
        existingPodcast ?? previewPodcast
    }

    private var availableAlternativeFeeds: [PodcastAlternativeFeed] {
        newPodcastFeed.alternativeFeeds.filter { $0.url != newPodcastFeed.url }
    }

    private var podcastTrailers: [PodcastTrailer] {
        displayedPodcast.optionalTags?.podcastTrailers(baseURL: displayedPodcast.feed) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                PodcastRowView(podcast: displayedPodcast)

                if newPodcastFeed.url != nil {
                    NavigationLink(destination: PodcastBrowseView(feed: newPodcastFeed, modelContainer: modelContext.container)) {
                        EmptyView()
                    }
                    .opacity(0)
                }
            }

            if availableAlternativeFeeds.isEmpty == false {
                Menu {
                    ForEach(availableAlternativeFeeds) { alternativeFeed in
                        NavigationLink {
                            PodcastBrowseView(
                                feed: PodcastFeed(url: alternativeFeed.url, title: alternativeFeed.title),
                                modelContainer: modelContext.container
                            )
                        } label: {
                            Label(alternativeFeed.displayTitle, systemImage: "dot.radiowaves.left.and.right")
                        }
                    }
                } label: {
                    Label("Alternative Feeds", systemImage: "arrow.triangle.branch")
                        .font(.caption)
                }
                .buttonStyle(.glass(.clear))
            }

            PodcastTrailerButton(
                trailers: podcastTrailers,
                podcastTitle: displayedPodcast.title,
                artworkURL: displayedPodcast.imageURL
            )
        }
        .buttonStyle(.plain)
    }
}

struct PodcastTrailerButton: View {
    let trailers: [PodcastTrailer]
    let podcastTitle: String
    let artworkURL: URL?

    var body: some View {
        if trailers.count == 1, let trailer = trailers.first {
            Button {
                play(trailer)
            } label: {
                Label(trailerButtonTitle(for: trailer), systemImage: "play.rectangle")
            }
            .buttonStyle(.glass(.clear))
            .accessibilityLabel("Play podcast trailer")
        } else if trailers.count > 1 {
            Menu {
                ForEach(trailers) { trailer in
                    Button {
                        play(trailer)
                    } label: {
                        Label(trailer.displayTitle, systemImage: "play.rectangle")
                    }
                }
            } label: {
                Label("Trailers", systemImage: "play.rectangle")
            }
            .buttonStyle(.glass(.clear))
            .accessibilityLabel("Open podcast trailers")
        }
    }

    private func trailerButtonTitle(for trailer: PodcastTrailer) -> String {
        trailer.season == nil ? "Trailer" : trailer.displayTitle
    }

    private func play(_ trailer: PodcastTrailer) {
        Task {
            await Player.shared.playLiveStream(
                url: trailer.url,
                title: trailer.displayTitle,
                podcastTitle: podcastTitle,
                artworkURL: artworkURL,
                link: nil
            )
        }
    }
}
