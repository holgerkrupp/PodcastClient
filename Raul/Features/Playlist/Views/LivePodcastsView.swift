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
    static func entries(from podcasts: [Podcast], isEnabled: Bool, now: Date = .now) -> [LivePodcastEntry] {
        let candidates = podcasts.map { (podcast: $0, items: $0.liveItems) }
        return entries(from: candidates, isEnabled: isEnabled, now: now)
    }

    static func entries(
        from candidates: [(podcast: Podcast, items: [PodcastLiveItem])],
        isEnabled: Bool,
        now: Date = .now
    ) -> [LivePodcastEntry] {
        guard isEnabled else { return [] }

        return candidates
            .filter { $0.podcast.isSubscribed }
            .flatMap { candidate in
                candidate.items
                    .filter { isCurrentOrScheduled($0, now: now) }
                    .map { LivePodcastEntry(podcast: candidate.podcast, item: $0) }
            }
            .sorted {
                ($0.item.start ?? .distantPast, $0.item.id)
                    < ($1.item.start ?? .distantPast, $1.item.id)
            }
    }

    private static func isCurrentOrScheduled(_ item: PodcastLiveItem, now: Date) -> Bool {
        switch item.status {
        case .pending:
            guard let start = item.start else { return true }
            guard start > now else { return false }
            return item.end.map { $0 > now } ?? true
        case .live:
            if let end = item.end { return end > now }
            // Feeds can leave a live status behind after a broadcast. When no
            // end time is supplied, keep only recent starts as a fallback.
            return item.start.map { $0 >= now.addingTimeInterval(-24 * 60 * 60) } ?? true
        case .ended, .unknown(_):
            return false
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
                        description: Text("Current and scheduled live items from subscribed podcasts will appear here.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(liveEntries) { entry in
                                LivePodcastRow(
                                    podcast: entry.podcast,
                                    liveItem: entry.item
                                )
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Live podcasts")
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
        .accessibilityHint("Opens current and scheduled live podcasts")
        .accessibilityInputLabels([Text("Live podcasts"), Text("Live")])
    }
}

struct LivePodcastRow: View {
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .body) private var artworkSize: CGFloat = 120

    let podcast: Podcast
    let liveItem: PodcastLiveItem

    private var artworkURL: URL? {
        liveItem.artworkURL ?? podcast.imageURL
    }

    private var statusTitle: String {
        liveItem.status == .pending ? "SCHEDULED" : "LIVE"
    }

    private var scheduleText: String? {
        guard liveItem.status == .pending, let start = liveItem.start else { return nil }
        return start.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImageView(podcast: podcast, imageURL: liveItem.artworkURL)
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("Cover art for \(podcast.title)")

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(podcast.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(statusTitle)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(liveItem.status == .live ? Color.red : Color.secondary)
                }

                Text(liveItem.title)
                    .font(.headline)
                    .lineLimit(4)

                if let scheduleText {
                    Text(scheduleText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let summary = liveItem.summary, summary.isEmpty == false {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                HStack(spacing: 10) {
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
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 144, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(statusTitle.capitalized) \(liveItem.title), \(podcast.title)")
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
