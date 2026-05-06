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

    var body: some View {
        ZStack {
            PodcastRowView(podcast: displayedPodcast)

            if newPodcastFeed.url != nil {
                NavigationLink(destination: PodcastBrowseView(feed: newPodcastFeed, modelContainer: modelContext.container)) {
                    EmptyView()
                }
                .opacity(0)
            }
        }
        .buttonStyle(.plain)
    }
}
