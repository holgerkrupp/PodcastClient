import SwiftUI
import SwiftData

struct LivePodcastEntry: Identifiable {
    let podcast: Podcast
    let item: PodcastLiveItem

    var id: String {
        "\(String(describing: podcast.persistentModelID))-\(item.id)"
    }
}

enum LivePodcastDiscovery {
    /// Derives the live destination from the same subscribed podcast models that
    /// are refreshed by the feed pipeline. No separate live-state is persisted.
    static func entries(from podcasts: [Podcast], isEnabled: Bool) -> [LivePodcastEntry] {
        let candidates = podcasts.map { (podcast: $0, items: $0.liveItems) }
        return entries(from: candidates, isEnabled: isEnabled)
    }

    static func entries(
        from candidates: [(podcast: Podcast, items: [PodcastLiveItem])],
        isEnabled: Bool
    ) -> [LivePodcastEntry] {
        guard isEnabled else { return [] }

        return candidates
            .filter { $0.podcast.isSubscribed }
            .flatMap { candidate in
                candidate.items
                    .filter { $0.status == .live }
                    .map { LivePodcastEntry(podcast: candidate.podcast, item: $0) }
            }
            .sorted {
                ($0.item.start ?? .distantPast, $0.item.id)
                    < ($1.item.start ?? .distantPast, $1.item.id)
            }
    }
}

struct LivePodcastsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var subscribedPodcasts: [Podcast]
    @Query(filter: PodcastSettingsView.defaultSettingsFilter)
    private var defaultSettings: [PodcastSettings]

    init() {
        _subscribedPodcasts = Query(
            filter: #Predicate<Podcast> { $0.metaData?.isSubscribed != false },
            sort: [SortDescriptor<Podcast>(\.title)]
        )
    }

    private var liveEntries: [LivePodcastEntry] {
        LivePodcastDiscovery.entries(
            from: subscribedPodcasts,
            isEnabled: defaultSettings.first?.showLivePodcasts != false
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if liveEntries.isEmpty {
                    ContentUnavailableView(
                        "No Live Podcasts",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("Currently live subscribed podcasts will appear here.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 260), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(liveEntries) { entry in
                                LivePodcastCard(
                                    podcast: entry.podcast,
                                    liveItem: entry.item
                                )
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Live Podcasts")
            .platformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityLabel("Close live podcasts")
                }
            }
        }
    }
}

struct LivePodcastsToolbarButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text("LIVE")
                    .font(.caption.weight(.bold))
            } icon: {
                Image(systemName: "dot.radiowaves.left.and.right")
            }
        }
        .accessibilityLabel("Live podcasts")
        .accessibilityHint("Opens currently live subscribed podcasts")
        .accessibilityInputLabels([Text("Live podcasts"), Text("Live")])
    }
}

struct LivePodcastCard: View {
    @Environment(\.openURL) private var openURL

    let podcast: Podcast
    let liveItem: PodcastLiveItem

    private var artworkURL: URL? {
        liveItem.artworkURL ?? podcast.imageURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CoverImageView(imageURL: artworkURL)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("LIVE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.red)

            Text(liveItem.title)
                .font(.headline)
                .lineLimit(2)

            Text(podcast.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 8) {
                if liveItem.preferredStream != nil {
                    Button {
                        Task {
                            await Player.shared.playLiveItem(
                                liveItem,
                                podcastTitle: podcast.title,
                                artworkURL: artworkURL,
                                link: liveItem.link
                            )
                        }
                    } label: {
                        Label("Listen Live", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if hasMetadataActions {
                    Menu {
                        metadataActions
                    } label: {
                        Label("Live details", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Live details for \(liveItem.title)")
                    .accessibilityHint("Opens the live page, chat, or companion links")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live \(liveItem.title), \(podcast.title)")
    }

    private var hasMetadataActions: Bool {
        liveItem.link != nil || liveItem.chat.isEmpty == false || liveItem.contentLinks.isEmpty == false
    }

    @ViewBuilder
    private var metadataActions: some View {
        if let link = liveItem.link {
            Button {
                openURL(link)
            } label: {
                Label("Open Live Page", systemImage: "safari")
            }
        }

        ForEach(liveItem.chat) { chat in
            Button {
                openURL(chat.url)
            } label: {
                Label(chat.label, systemImage: "bubble.left.and.bubble.right")
            }
        }

        ForEach(liveItem.contentLinks) { contentLink in
            Button {
                openURL(contentLink.url)
            } label: {
                Label(contentLink.label, systemImage: "link")
            }
        }
    }
}
