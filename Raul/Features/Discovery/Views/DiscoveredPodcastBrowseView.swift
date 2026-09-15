//
//  DiscoveredPodcastBrowseView.swift
//  Raul
//
//  The hand-off from discovery into the app's ordinary podcast screen.
//
//  Selecting a discovered show opens `PodcastBrowseView` directly — the same
//  screen a podcast found through Apple's directory opens, with the same header,
//  episode list and Subscribe button. There is no discovery-specific detail
//  screen in between, because everything it would show is already there.
//
//  Most providers hand over an RSS feed with the show, so this view resolves to
//  `PodcastBrowseView` on its first render and is never seen. Only the providers
//  that have to look a feed up (ARD, RTP, and SRG search results) briefly show a
//  progress view first.
//

import SwiftUI
import SwiftData

struct DiscoveredPodcastBrowseView: View {
    @Environment(\.modelContext) private var context
    @StateObject private var viewModel: DiscoveredPodcastFeedResolution

    private let podcast: DiscoveredPodcast
    private let registry: PodcastDiscoveryRegistry

    init(podcast: DiscoveredPodcast, registry: PodcastDiscoveryRegistry = .shared) {
        self.podcast = podcast
        self.registry = registry
        _viewModel = StateObject(
            wrappedValue: DiscoveredPodcastFeedResolution(podcast: podcast, registry: registry)
        )
    }

    private var broadcaster: PublicBroadcaster? {
        registry.broadcaster(withID: podcast.broadcasterID)
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .resolved(let feedURL):
                PodcastBrowseView(
                    feed: viewModel.podcastFeed(for: feedURL),
                    modelContainer: context.container
                )

            case .resolving:
                ProgressView()
                    .accessibilityLabel("Loading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(podcast.title)

            case .unavailable:
                ContentUnavailableView {
                    Label("Feed unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("This podcast cannot be opened right now.")
                } actions: {
                    if let website = podcast.webpageURL ?? broadcaster?.website {
                        Link(destination: website) {
                            Label("Open Broadcaster Website", systemImage: "safari")
                        }
                    }
                }
                .navigationTitle(podcast.title)
            }
        }
        .task {
            await viewModel.resolveFeedIfNeeded()
        }
    }
}

/// Resolves a discovered show to an ordinary RSS feed and expresses it as the
/// app's pre-subscription `PodcastFeed`, so the existing import path needs no
/// discovery awareness.
@MainActor
final class DiscoveredPodcastFeedResolution: ObservableObject {
    enum State: Equatable {
        case resolving
        case resolved(URL)
        case unavailable
    }

    @Published private(set) var state: State = .resolving

    private let podcast: DiscoveredPodcast
    private let service: PodcastDiscoveryService
    private var didResolve = false

    init(podcast: DiscoveredPodcast, registry: PodcastDiscoveryRegistry = .shared) {
        self.podcast = podcast
        self.service = PodcastDiscoveryService(registry: registry)

        // Providers that publish feeds directly land on the podcast with no
        // intermediate state at all.
        if let feedURL = podcast.feedURL {
            self.state = .resolved(feedURL)
            self.didResolve = true
        }
    }

    func resolveFeedIfNeeded() async {
        guard didResolve == false else { return }
        didResolve = true
        state = .resolving

        do {
            state = .resolved(try await service.resolveFeed(for: podcast))
        } catch is CancellationError {
            didResolve = false
        } catch {
            // Provider errors stay internal: the user is offered the
            // broadcaster's own site instead.
            state = .unavailable
        }
    }

    /// Seeds the feed with what discovery already knows, so the podcast header
    /// has a title and artwork while the feed itself is still loading.
    func podcastFeed(for feedURL: URL) -> PodcastFeed {
        let feed = PodcastFeed(url: feedURL, fetchMetadataIfNeeded: false)
        feed.title = podcast.title
        feed.description = podcast.summary
        feed.artist = podcast.author
        feed.artworkURL = podcast.artworkURL
        feed.link = podcast.webpageURL
        return feed
    }
}
