import SwiftUI
import SwiftData

struct PodcastPodrollView: View {
    let podcastTitle: String
    let items: [PodcastPodrollItem]

    @StateObject private var feedLoader: PodcastPodrollFeedLoader

    init(podcastTitle: String, items: [PodcastPodrollItem]) {
        self.podcastTitle = podcastTitle
        self.items = items
        self._feedLoader = StateObject(wrappedValue: PodcastPodrollFeedLoader(items: items))
    }

    var body: some View {
        List {
            Section {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    PodcastPodrollRow(item: item, feed: feedLoader.feed(for: item, at: index))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0,
                                             leading: 0,
                                             bottom: 0,
                                             trailing: 0))
                }
            } header: {
                Text(podcastTitle)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Podroll")
        .task(id: items.map(\.id).joined(separator: "|")) {
            await feedLoader.loadFeedsIfNeeded()
        }
    }
}

private struct PodcastPodrollRow: View {
    @Environment(\.modelContext) private var modelContext

    let item: PodcastPodrollItem
    let feed: PodcastFeed

    var body: some View {
        if item.hasResolvableFeed {
            ZStack {
                content
                NavigationLink(destination: PodcastBrowseView(feed: feed, modelContainer: modelContext.container)) {
                    EmptyView()
                }.opacity(0)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(item.title ?? "Unknown")")
            .accessibilityHint("Opens this podcasts details screen")
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(.init(top: 0,
                                 leading: 0,
                                 bottom: 0,
                                 trailing: 0))
            .ignoresSafeArea()
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            SubscribeToPodcastView(
                newPodcastFeed: feed,
                showsBrowseNavigationLink: false
            )

            if item.hasResolvableFeed == false {
                Label("Feed URL unavailable", systemImage: "link.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private final class PodcastPodrollFeedLoader: ObservableObject {
    private let items: [PodcastPodrollItem]
    private let fallbackFeeds: [PodcastFeed]

    @Published private var resolvedFeeds: [URL: PodcastFeed] = [:]

    init(items: [PodcastPodrollItem]) {
        self.items = items
        self.fallbackFeeds = items.map { $0.podcastFeed(fetchMetadataIfNeeded: false) }
    }

    func feed(for item: PodcastPodrollItem, at index: Int) -> PodcastFeed {
        if let feedURL = item.feedURL, let resolvedFeed = resolvedFeeds[feedURL] {
            return resolvedFeed
        }

        return fallbackFeeds[index]
    }

    func loadFeedsIfNeeded() async {
        let uniqueItems = Dictionary(grouping: items, by: \.feedURL)
            .compactMap { key, value -> PodcastPodrollItem? in
                key == nil ? nil : value.first
            }

        await withTaskGroup(of: (URL, PodcastFeed)?.self) { group in
            for item in uniqueItems {
                guard let feedURL = item.feedURL else { continue }

                group.addTask {
                    guard let feed = await PodcastPodrollFeedCache.loadFeed(for: item) else {
                        return nil
                    }

                    return (feedURL, feed)
                }
            }

            for await result in group {
                guard let (feedURL, feed) = result else { continue }
                resolvedFeeds[feedURL] = feed
            }
        }
    }
}

@MainActor
private enum PodcastPodrollFeedCache {
    private static var feeds: [URL: PodcastFeed] = [:]
    private static var loadingTasks: [URL: Task<PodcastFeed, Error>] = [:]
    private static var failedURLs = Set<URL>()

    static func loadFeed(for item: PodcastPodrollItem) async -> PodcastFeed? {
        guard let feedURL = item.feedURL else {
            return nil
        }

        if let feed = feeds[feedURL] {
            return feed
        }

        guard failedURLs.contains(feedURL) == false else {
            return nil
        }

        if let loadingTask = loadingTasks[feedURL] {
            return try? await loadingTask.value
        }

        let loadingTask = Task {
            let resolution = try await PodcastFeedResolver.resolve(url: feedURL)

            switch resolution {
            case .podcast(let feed):
                return feed
            case .requiresBasicAuth:
                throw PodcastFeedResolverError.authenticationRequired(feedURL)
            }
        }

        loadingTasks[feedURL] = loadingTask

        do {
            let feed = try await loadingTask.value
            feeds[feedURL] = feed
            loadingTasks[feedURL] = nil
            return feed
        } catch {
            failedURLs.insert(feedURL)
            loadingTasks[feedURL] = nil
            return nil
        }
    }
}

#Preview("Podroll") {
    NavigationStack {
        PodcastPodrollView(
            podcastTitle: "Preview Engineering Weekly",
            items: [
                PodcastPodrollItem(
                    node: NamespaceNode(
                        name: "podcast:remoteItem",
                        attributes: [
                            "feedGuid": "29cdca4a-32d8-56ba-b48b-09a011c5daa9",
                            "feedUrl": "https://feeds.podcastindex.org/pc20.xml",
                            "title": "Podcasting 2.0"
                        ]
                    ),
                    baseURL: nil
                )!,
                PodcastPodrollItem(
                    node: NamespaceNode(
                        name: "podcast:remoteItem",
                        attributes: [
                            "feedGuid": "396d9ae0-da7e-5557-b894-b606231fa3ea",
                            "title": "GUID-only Recommendation"
                        ]
                    ),
                    baseURL: nil
                )!
            ]
        )
    }
}
