//
//  SubscribeToPodcastView.swift
//  Raul
//
//  Created by Holger Krupp on 03.04.25.
//

import SwiftUI
import SwiftData
import ESADesignKit

struct SubscribeToPodcastView: View {
    @Environment(\.modelContext) private var modelContext

    @Bindable var newPodcastFeed: PodcastFeed
    var existingPodcast: Podcast?
    private let showsBrowseNavigationLink: Bool

    init(newPodcastFeed: PodcastFeed, existingPodcast: Podcast? = nil, showsBrowseNavigationLink: Bool = true) {
        self.newPodcastFeed = newPodcastFeed
        self.existingPodcast = existingPodcast
        self.showsBrowseNavigationLink = showsBrowseNavigationLink
    }

    private var availableAlternativeFeeds: [PodcastAlternativeFeed] {
        newPodcastFeed.alternativeFeeds.filter { $0.url != newPodcastFeed.url }
    }

    private var podcastTrailers: [PodcastTrailer] {
        newPodcastFeed.optionalTags?.podcastTrailers(baseURL: newPodcastFeed.url) ?? []
    }

    private var deadFeedStatus: URLstatus? {
        guard let status = newPodcastFeed.status, status.isDeadFeedResponse else { return nil }
        return status
    }

    private var privateProvider: PremiumPodcastProviderDescriptor? {
        guard let url = newPodcastFeed.url, url.isLikelyPrivatePodcastURL else { return nil }
        return PremiumPodcastProviderRegistry.descriptor(for: url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let existingPodcast {
                    PodcastRowView(podcast: existingPodcast, density: .compact)
                } else {
                    PodcastRowContentView(
                        presentation: PodcastRowPresentation(
                            identity: newPodcastFeed.url.map(PodcastFeedIdentity.normalizedFeedURLString)
                                ?? newPodcastFeed.title
                                ?? "new-podcast",
                            feedURL: newPodcastFeed.url,
                            title: newPodcastFeed.title
                                ?? newPodcastFeed.url?.absoluteString
                                ?? "New Podcast",
                            author: newPodcastFeed.artist,
                            summary: newPodcastFeed.description,
                            artworkURL: newPodcastFeed.artworkURL,
                            status: newPodcastFeed.existing ? .subscribed : .notSubscribed
                        ),
                        density: .compact
                    )
                }

                if showsBrowseNavigationLink, newPodcastFeed.url != nil, deadFeedStatus == nil {
                    NavigationLink(destination: PodcastBrowseView(feed: newPodcastFeed, modelContainer: modelContext.container)) {
                        EmptyView()
                    }
                    .opacity(0)
                }
            }

            if let privateProvider {
                VStack(alignment: .leading, spacing: 5) {
                    Label(privateProvider.displayName, systemImage: "lock.shield.fill")
                        .font(.subheadline.weight(.semibold))
                    Text(privateProvider.onboardingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("This feed link is personal and will be stored securely. It is not included in sync or export.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .combine)
            }

            if let deadFeedStatus {
                Label(deadFeedStatus.displayMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.red.opacity(0.12))
                    )
                    .accessibilityLabel("Feed unavailable: \(deadFeedStatus.displayMessage)")
            }

            if newPodcastFeed.importNeedsRetry {
                Label("Subscribed — import needs retry", systemImage: "arrow.clockwise.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.orange.opacity(0.12))
                    )
                    .accessibilityElement(children: .combine)
            }

            if newPodcastFeed.isImportingEpisodes {
                Label("Subscribed — importing episodes", systemImage: "arrow.down.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.green.opacity(0.12))
                    )
                    .accessibilityElement(children: .combine)
            }

            if let subscriptionErrorMessage = newPodcastFeed.subscriptionErrorMessage {
                Label(subscriptionErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.red.opacity(0.12))
                    )
                    .accessibilityElement(children: .combine)
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
                podcastTitle: newPodcastFeed.title ?? "New Podcast",
                artworkURL: newPodcastFeed.artworkURL
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
