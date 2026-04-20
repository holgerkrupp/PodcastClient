import SwiftUI
import SwiftData
import RichText

@MainActor
final class PodcastBrowseViewModel: ObservableObject {
    @Published var podcastFeed: PodcastFeed
    @Published var episodes: [PodcastEpisodeDraft] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var isSubscribing = false
    @Published var isSubscribed = false
    @Published var errorMessage: String?

    private let modelContainer: ModelContainer
    private let episodeBatchSize = 20
    private var initialPageLoaded = false
    private var currentPageDocument: PodcastFeedDocument?
    private var currentPageNextURL: URL?
    private var currentPageIsPartial = false
    private var currentPageLoadedEpisodeCount = 0

    init(feed: PodcastFeed, modelContainer: ModelContainer) {
        self.podcastFeed = feed
        self.modelContainer = modelContainer
    }

    func loadInitialPageIfNeeded() async {
        guard initialPageLoaded == false else { return }
        initialPageLoaded = true
        await loadPage(from: podcastFeed.url, maximumEpisodes: episodeBatchSize, isInitialLoad: true)
    }

    func reload() async {
        initialPageLoaded = false
        currentPageDocument = nil
        currentPageNextURL = nil
        currentPageIsPartial = false
        currentPageLoadedEpisodeCount = 0
        episodes.removeAll()
        errorMessage = nil
        await loadInitialPageIfNeeded()
    }

    func loadNextPageIfNeeded(for episode: PodcastEpisodeDraft) async {
        guard episode == episodes.last else { return }
        await loadMoreEpisodesIfNeeded()
    }

    var hasMoreEpisodes: Bool {
        currentPageIsPartial || currentPageNextURL != nil
    }

    func queue(_ episode: PodcastEpisodeDraft, to position: Playlist.Position) async {
        guard isLoading == false else { return }
        errorMessage = nil
        do {
            try await SubscriptionManager(modelContainer: modelContainer).queueBrowseEpisode(
                episode,
                from: podcastFeed,
                to: position
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func subscribe() async {
        guard isSubscribing == false else { return }
        guard podcastFeed.url != nil else {
            errorMessage = "This podcast does not expose a feed URL."
            return
        }
        isSubscribing = true
        defer {
            isSubscribing = false
        }

        do {
            _ = try await SubscriptionManager(modelContainer: modelContainer).addToLibrary(podcastFeed, subscribe: true)
            podcastFeed.existing = true
            isSubscribed = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMoreEpisodesIfNeeded() async {
        guard isLoadingMore == false else { return }
        if currentPageIsPartial, let currentPageDocument {
            let nextLimit = currentPageLoadedEpisodeCount + episodeBatchSize
            await loadPage(document: currentPageDocument, maximumEpisodes: nextLimit, isInitialLoad: false)
            return
        }

        guard let currentPageNextURL else { return }
        await loadPage(from: currentPageNextURL, maximumEpisodes: episodeBatchSize, isInitialLoad: false)
    }

    private func loadPage(from url: URL?, maximumEpisodes: Int, isInitialLoad: Bool) async {
        guard let url else {
            errorMessage = "This podcast does not expose a feed URL."
            return
        }

        do {
            let document = try await PodcastParser.downloadFeed(from: url)
            await loadPage(document: document, maximumEpisodes: maximumEpisodes, isInitialLoad: isInitialLoad)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadPage(document: PodcastFeedDocument, maximumEpisodes: Int, isInitialLoad: Bool) async {
        if isInitialLoad {
            isLoading = true
        } else {
            isLoadingMore = true
        }

        defer {
            isLoading = false
            isLoadingMore = false
        }

        do {
            let page = try await PodcastParser.parsePage(from: document, maximumEpisodes: maximumEpisodes)

            if isInitialLoad {
                let mergedFeed = page.feed
                mergedFeed.source = podcastFeed.source ?? mergedFeed.source
                mergedFeed.subtitle = podcastFeed.subtitle ?? mergedFeed.subtitle
                mergedFeed.title = mergedFeed.title ?? podcastFeed.title
                mergedFeed.description = mergedFeed.description ?? podcastFeed.description
                mergedFeed.artist = mergedFeed.artist ?? podcastFeed.artist
                mergedFeed.artworkURL = mergedFeed.artworkURL ?? podcastFeed.artworkURL
                mergedFeed.lastRelease = mergedFeed.lastRelease ?? podcastFeed.lastRelease
                podcastFeed = mergedFeed
            }
            currentPageDocument = document
            let currentEpisodes = episodes
            episodes.append(contentsOf: page.episodes.filter { currentEpisodes.contains($0) == false })
            currentPageNextURL = page.nextPageURL
            currentPageIsPartial = page.isPartial
            currentPageLoadedEpisodeCount = page.episodes.count
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PodcastBrowseView: View {
    @StateObject private var viewModel: PodcastBrowseViewModel
    @State private var backgroundUIImage: UIImage?

    init(feed: PodcastFeed, modelContainer: ModelContainer) {
        _viewModel = StateObject(wrappedValue: PodcastBrowseViewModel(feed: feed, modelContainer: modelContainer))
    }

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Section {
                PodcastBrowseHeaderView(
                    feed: viewModel.podcastFeed,
                    isSubscribed: viewModel.isSubscribed,
                    isSubscribing: viewModel.isSubscribing,
                    subscribeAction: {
                        await viewModel.subscribe()
                    }
                )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Section {
                if viewModel.isLoading && viewModel.episodes.isEmpty {
                    ProgressView("Loading episodes...")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else if viewModel.episodes.isEmpty {
                    ContentUnavailableView("No Episodes Yet", systemImage: "dot.radiowaves.left.and.right")
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(viewModel.episodes) { episode in
                        PodcastBrowseEpisodeRowView(
                            episode: episode,
                            podcastFeed: viewModel.podcastFeed,
                            queueAction: { position in
                                await viewModel.queue(episode, to: position)
                            }
                        )
                        .onAppear {
                            Task {
                                await viewModel.loadNextPageIfNeeded(for: episode)
                            }
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }

                    if viewModel.isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }

                    if viewModel.hasMoreEpisodes || viewModel.isLoadingMore {
                        Text("More episodes load as you scroll.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }
                }
            } header: {
                Text("Episodes")
            }
        }
        .listStyle(.plain)
        .listRowSpacing(0)
        .padding(.top, 0)
        .navigationTitle(viewModel.podcastFeed.title ?? "Browse Episodes")
        .task {
            await viewModel.loadInitialPageIfNeeded()
        }
        .task(id: viewModel.podcastFeed.artworkURL) {
            await loadBackgroundImage()
        }
        .refreshable {
            await viewModel.reload()
        }
        .background {
            if let backgroundUIImage {
                Image(uiImage: backgroundUIImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.all)
                    .blur(radius: 20)
                    .opacity(0.5)
            } else {
                Color.accent.ignoresSafeArea()
            }
        }
    }

    private func loadBackgroundImage() async {
        guard let imageURL = viewModel.podcastFeed.artworkURL else {
            await MainActor.run {
                backgroundUIImage = nil
            }
            return
        }

        let uiImage = await ImageLoaderAndCache.loadUIImage(from: imageURL)
        await MainActor.run {
            backgroundUIImage = uiImage
        }
    }
}

private struct PodcastBrowseHeaderView: View {
    let feed: PodcastFeed
    let isSubscribed: Bool
    let isSubscribing: Bool
    let subscribeAction: () async -> Void
    @Environment(\.deviceUIStyle) var style

    private var lastUpdatedText: String? {
        feed.lastRelease?.formatted(date: .numeric, time: .shortened)
    }

    private var lastRefreshText: String? {
        feed.importedLastRefresh?.formatted(date: .numeric, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let lastUpdatedText {
                    Text("Last updated: \(lastUpdatedText)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let lastRefreshText {
                    Text("Last refresh: \(lastRefreshText)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                CoverImageView(imageURL: feed.artworkURL)
                    .frame(width: 50, height: 50)
                    .cornerRadius(8)

                VStack(alignment: .leading, spacing: 4) {
                    if let artist = feed.artist, artist.isEmpty == false {
                        Text(artist)
                            .font(.caption)
                    }
                    Text(feed.title ?? "Untitled Podcast")
                        .font(.headline)
                        .lineLimit(2)
                    if let subtitle = feed.subtitle, subtitle.isEmpty == false {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            if feed.funding.isEmpty == false {
                HStack {
                    ForEach(feed.funding) { fund in
                        Link(destination: fund.url) {
                            Label(fund.label, systemImage: style.currencySFSymbolName)
                        }
                        .buttonStyle(.glass(.clear))

                        if fund != feed.funding.last {
                            Spacer()
                        }
                    }
                }
            }

            if let copyright = feed.copyright, copyright.isEmpty == false {
                Text(copyright)
                    .font(.caption)
            }

            if feed.social.isEmpty == false {
                SocialView(socials: feed.social)
                    .padding()
            }

            if feed.people.isEmpty == false {
                PeopleView(people: feed.people)
                    .padding()
            }

            if let optionalTags = feed.optionalTags {
                PodcastNamespaceMetadataView(optionalTags: optionalTags)
                    .padding()
            }

            if let description = feed.description, description.isEmpty == false {
                RichText(html: description)
                    .linkColor(light: Color.secondary, dark: Color.secondary)
                    .backgroundColor(.transparent)
                    .padding()
            }

            if let link = feed.link {
                Link(destination: link) {
                    Label("Open in Browser", systemImage: "safari")
                }
                .buttonStyle(.glass(.clear))
            }

            Button {
                Task {
                    await subscribeAction()
                }
            } label: {
                if isSubscribed {
                    Label("Subscribed", systemImage: "checkmark.circle.fill")
                } else if isSubscribing {
                    ProgressView()
                        .frame(width: 50)
                } else {
                    Label("Subscribe", systemImage: "plus.circle")
                }
            }
            .buttonStyle(.glass(.clear))
            .disabled(feed.url == nil || isSubscribed || isSubscribing)

            Text("This feed stays transient until you queue an episode. That way we only write podcasts and episodes you actually listen to.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PodcastBrowseEpisodeRowView: View {
    let episode: PodcastEpisodeDraft
    let podcastFeed: PodcastFeed
    let queueAction: (Playlist.Position) async -> Void

    @State private var isQueueing = false
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 210
    @ScaledMetric(relativeTo: .body) private var artworkSize: CGFloat = 120

    private var displayTime: String {
        let duration = episode.duration ?? 0
        return Duration.seconds(duration).formatted(.units(width: .narrow))
    }

    private var publishText: String {
        episode.publishDate?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown Date"
    }

    private func startQueue(_ position: Playlist.Position) {
        guard isQueueing == false else { return }
        isQueueing = true
        Task {
            await queueAction(position)
            await MainActor.run {
                isQueueing = false
            }
        }
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    CoverImageView(imageURL: episode.imageURL ?? podcastFeed.artworkURL)
                        .frame(width: artworkSize, height: artworkSize)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            Text(podcastFeed.title ?? "Untitled Podcast")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            Text(publishText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(episode.title)
                            .font(.headline)
                            .lineLimit(4)
                            .foregroundStyle(.primary)

                        Spacer(minLength: 0)

                        Text(displayTime)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let author = episode.author, author.isEmpty == false {
                            Text(author)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if let subtitle = episode.subtitle, subtitle.isEmpty == false {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        if let desc = episode.desc, desc.isEmpty == false {
                            Text(desc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        
                        GlassEffectContainer(spacing: 20.0) {
                            HStack(spacing: 0.0) {
                                Button {
                                    startQueue(.front)
                                } label: {
                                    Image(systemName: "arrow.up.to.line")
                                        .symbolRenderingMode(.hierarchical)
                                        .scaledToFit()
                                        .padding(5)
                                        .minimumScaleFactor(0.5)
                                        .frame(width: 50)
                                }
                                .buttonStyle(.glass(.clear))
                                .clipShape(Circle())
                                .disabled(isQueueing)
                                .accessibilityLabel("Add to Up Next")
                                
                                Button {
                                    startQueue(.end)
                                } label: {
                                    Image(systemName: "arrow.down.to.line")
                                        .symbolRenderingMode(.hierarchical)
                                        .scaledToFit()
                                        .padding(5)
                                        .minimumScaleFactor(0.5)
                                        .frame(width: 50)
                                }
                                .buttonStyle(.glass(.clear))
                                .clipShape(Circle())
                                .disabled(isQueueing)
                                .accessibilityLabel("Add to End")
                                
                                Spacer()
                                
                                if isQueueing {
                                    ProgressView()
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: artworkSize, alignment: .topLeading)
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .overlay {
                        CoverImageView(imageURL: episode.imageURL ?? podcastFeed.artworkURL)
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .blur(radius: 8)
                            .opacity(0.45)
                            .clipped()
                    }
            }
        }
    }
}
