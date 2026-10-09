import SwiftUI
import SwiftData
import ESADesignKit

@MainActor
final class PodcastBrowseViewModel: ObservableObject {
    @Published var podcastFeed: PodcastFeed
    @Published var episodes: [PodcastEpisodeDraft] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var isSubscribing = false
    @Published var isSubscribed = false
    @Published var playingEpisodeID: String?
    @Published var errorMessage: String?
    @Published var pageLoadFailed = false

    private let modelContainer: ModelContainer
    private var initialPageLoaded = false
    private var episodePager = PodcastFeedEpisodePager(batchSize: 20)
    private var displayedEpisodeIDs = Set<String>()
    private var requestGeneration = 0
    private var activePageDownload: Task<PodcastFeedDocument, Error>?

    init(feed: PodcastFeed, modelContainer: ModelContainer) {
        self.podcastFeed = feed
        self.modelContainer = modelContainer
    }

    func loadInitialPageIfNeeded() async {
        guard initialPageLoaded == false else { return }
        initialPageLoaded = true
        await refreshSubscriptionStatus()
        await loadPage(from: podcastFeed.url, isInitialLoad: true)
    }

    func reload() async {
        requestGeneration &+= 1
        activePageDownload?.cancel()
        activePageDownload = nil
        initialPageLoaded = false
        isLoading = false
        isLoadingMore = false
        episodePager.reset()
        errorMessage = nil
        pageLoadFailed = false
        await refreshSubscriptionStatus()
        await loadInitialPageIfNeeded()
    }

    /// The discovery hint is advisory; persisted feed identity is authoritative.
    func refreshSubscriptionStatus() async {
        guard let feedURL = podcastFeed.url else {
            isSubscribed = false
            return
        }
        isSubscribed = await PodcastSubscriptionPersistence.isSubscribed(
            feedURL: feedURL,
            legacyContainer: modelContainer
        )
    }

    func retryPageLoad() async {
        guard pageLoadFailed else { return }
        pageLoadFailed = false
        errorMessage = nil
        if episodes.isEmpty {
            initialPageLoaded = false
            await loadInitialPageIfNeeded()
        } else {
            await loadMoreEpisodesIfNeeded()
        }
    }

    func loadNextPageIfNeeded(for episode: PodcastEpisodeDraft) async {
        guard episode == episodes.last else { return }
        await loadMoreEpisodesIfNeeded()
    }

    var hasMoreEpisodes: Bool {
        episodePager.hasMoreEpisodes
    }

    func queue(_ episode: PodcastEpisodeDraft, to position: Playlist.Position) async -> Bool {
        guard isLoading == false else { return false }
        errorMessage = nil
        do {
            try await SubscriptionManager(modelContainer: modelContainer).queueBrowseEpisode(
                episode,
                from: podcastFeed,
                to: position
            )
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func play(_ episode: PodcastEpisodeDraft) async -> Bool {
        guard playingEpisodeID == nil else { return false }
        playingEpisodeID = episode.id
        defer { playingEpisodeID = nil }
        errorMessage = nil

        do {
            let episodeURL = try await prepareEpisodeForAction(episode)
            await Player.shared.playEpisode(episodeURL, playDirectly: true)
            guard Player.shared.currentEpisodeURL == episodeURL else {
                errorMessage = "Could not start this episode."
                return false
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func prepareEpisodeForAction(_ episode: PodcastEpisodeDraft) async throws -> URL {
        try await SubscriptionManager(modelContainer: modelContainer)
            .prepareBrowseEpisodeForPlayback(episode, from: podcastFeed)
    }

    func subscribe() async -> Bool {
        guard isSubscribing == false else { return false }
        guard podcastFeed.url != nil else {
            errorMessage = "This podcast does not expose a feed URL."
            return false
        }
        isSubscribing = true
        defer {
            isSubscribing = false
        }

        do {
            let modelContainer = modelContainer
            let podcastFeed = podcastFeed
            _ = try await Task.detached(priority: .utility) {
                try await SubscriptionManager(modelContainer: modelContainer).addToLibrary(podcastFeed, subscribe: true)
            }.value
            podcastFeed.existing = true
            isSubscribed = true
            errorMessage = if podcastFeed.importNeedsRetry {
                "Subscribed — episode import needs retry. You can retry it from Podcast Detail."
            } else if podcastFeed.isImportingEpisodes {
                "Subscribed — importing episodes."
            } else {
                nil
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func loadAlternativeFeed(_ alternativeFeed: PodcastAlternativeFeed) async {
        guard isSubscribing == false else { return }

        let replacementFeed = PodcastFeed(
            url: alternativeFeed.url,
            title: alternativeFeed.title,
            source: podcastFeed.source,
            accessCredential: podcastFeed.accessCredential,
            accessKind: podcastFeed.accessKind,
            fetchMetadataIfNeeded: false
        )
        podcastFeed = replacementFeed
        episodes.removeAll()
        displayedEpisodeIDs.removeAll()
        await reload()
    }

    private func loadMoreEpisodesIfNeeded() async {
        guard isLoadingMore == false, isLoading == false else { return }
        if episodePager.hasUndeliveredEpisodes {
            appendUnique(episodePager.nextBatch())
            return
        }

        guard let nextPageURL = episodePager.nextPageURL else { return }
        await loadPage(from: nextPageURL, isInitialLoad: false)
    }

    private func loadPage(from url: URL?, isInitialLoad: Bool) async {
        guard let url else {
            errorMessage = "This podcast does not expose a feed URL."
            return
        }

        guard isLoading == false, isLoadingMore == false else { return }
        guard episodePager.hasVisited(url) == false else {
            errorMessage = "This feed links to a page that has already been loaded."
            return
        }
        if isInitialLoad { isLoading = true } else { isLoadingMore = true }
        pageLoadFailed = false
        let generation = requestGeneration
        let retainedEpisodes = isInitialLoad ? episodes : []
        defer {
            if generation == requestGeneration {
                isLoading = false
                isLoadingMore = false
                activePageDownload = nil
            }
        }
        let downloadSignpostID = PodcastDiscoverySignposts.begin("Browse Feed Download")
        do {
            let downloadTask = Task {
                try await PodcastParser.downloadFeed(from: url, profile: accessProfile)
            }
            activePageDownload = downloadTask
            let document = try await downloadTask.value
            PodcastDiscoverySignposts.end("Browse Feed Download", id: downloadSignpostID)
            guard generation == requestGeneration else { return }
            await loadPage(
                document: document,
                requestedURL: url,
                isInitialLoad: isInitialLoad,
                retainedEpisodes: retainedEpisodes,
                generation: generation
            )
        } catch {
            PodcastDiscoverySignposts.end("Browse Feed Download", id: downloadSignpostID)
            guard generation == requestGeneration else { return }
            errorMessage = error.localizedDescription
            pageLoadFailed = true
        }
    }

    private func loadPage(
        document: PodcastFeedDocument,
        requestedURL: URL,
        isInitialLoad: Bool,
        retainedEpisodes: [PodcastEpisodeDraft],
        generation: Int
    ) async {
        let parseSignpostID = PodcastDiscoverySignposts.begin("Browse Feed Parse")
        do {
            // Parse each XML document once. Subsequent scroll batches expose
            // already-decoded drafts instead of reparsing from the beginning.
            let page = try await PodcastParser.parsePage(from: document)
            PodcastDiscoverySignposts.end("Browse Feed Parse", id: parseSignpostID, count: page.episodes.count)
            guard generation == requestGeneration else { return }

            if isInitialLoad {
                let mergedFeed = page.feed
                mergedFeed.source = podcastFeed.source ?? mergedFeed.source
                mergedFeed.subtitle = podcastFeed.subtitle ?? mergedFeed.subtitle
                mergedFeed.title = mergedFeed.title ?? podcastFeed.title
                mergedFeed.description = mergedFeed.description ?? podcastFeed.description
                mergedFeed.artist = mergedFeed.artist ?? podcastFeed.artist
                mergedFeed.artworkURL = mergedFeed.artworkURL ?? podcastFeed.artworkURL
                mergedFeed.lastRelease = mergedFeed.lastRelease ?? podcastFeed.lastRelease
                mergedFeed.accessCredential = podcastFeed.accessCredential
                mergedFeed.accessKind = podcastFeed.accessKind
                podcastFeed = mergedFeed
            }
            let refreshedBatch = episodePager.appendPage(
                page.episodes,
                requestedURL: requestedURL,
                nextPageURL: page.nextPageURL
            )
            if isInitialLoad, retainedEpisodes.isEmpty == false {
                var refreshedIDs = Set(refreshedBatch.map(\.id))
                episodes = refreshedBatch + retainedEpisodes.filter { refreshedIDs.insert($0.id).inserted }
                displayedEpisodeIDs = Set(episodes.map(\.id))
            } else {
                appendUnique(refreshedBatch)
            }
            errorMessage = nil
            pageLoadFailed = false
        } catch {
            PodcastDiscoverySignposts.end("Browse Feed Parse", id: parseSignpostID)
            guard generation == requestGeneration else { return }
            errorMessage = error.localizedDescription
            pageLoadFailed = true
        }
    }

    private func appendUnique(_ newEpisodes: [PodcastEpisodeDraft]) {
        episodes.append(contentsOf: newEpisodes.filter { displayedEpisodeIDs.insert($0.id).inserted })
    }

    private var accessProfile: PodcastAccessProfile? {
        guard let credential = podcastFeed.accessCredential,
              let feedURL = podcastFeed.url else { return nil }
        let kind = podcastFeed.accessKind ?? {
            switch credential {
            case .privateURL: return PodcastAccessKind.privateURL
            case .httpBasic: return PodcastAccessKind.httpBasic
            case .bearerToken: return PodcastAccessKind.bearerToken
            }
        }()
        return PodcastAccessProfile.make(for: feedURL, kind: kind)
    }
}

struct PodcastBrowseView: View {
    @StateObject private var viewModel: PodcastBrowseViewModel
    @Query(filter: PodcastSettingsView.defaultSettingsFilter) private var defaultSettings: [PodcastSettings]
    @Environment(\.scenePhase) private var scenePhase

    init(feed: PodcastFeed, modelContainer: ModelContainer) {
        _viewModel = StateObject(wrappedValue: PodcastBrowseViewModel(feed: feed, modelContainer: modelContainer))
    }

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorMessage)
                        .font(.footnote)
                        .esaForeground(.secondary)
                    if viewModel.pageLoadFailed {
                        Button("Retry loading episodes") {
                            Task { await viewModel.retryPageLoad() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            Section {
                PodcastBrowseHeaderView(
                    feed: viewModel.podcastFeed,
                    isSubscribed: viewModel.isSubscribed,
                    isSubscribing: viewModel.isSubscribing,
                    showsLiveMetadata: defaultSettings.first?.showLivePodcasts != false,
                    subscribeAction: {
                        _ = await viewModel.subscribe()
                    },
                    alternativeFeedAction: { alternativeFeed in
                        await viewModel.loadAlternativeFeed(alternativeFeed)
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
                            isSubscribed: viewModel.isSubscribed,
                            isPlaying: viewModel.playingEpisodeID == episode.id,
                            queueAction: { position in
                                await viewModel.queue(episode, to: position)
                            },
                            playAction: {
                                await viewModel.play(episode)
                            },
                            prepareAction: {
                                try await viewModel.prepareEpisodeForAction(episode)
                            },
                            subscribeAction: {
                                await viewModel.subscribe()
                            }
                        )
                        .equatable()
                        .onAppear {
                            Task {
                                await viewModel.loadNextPageIfNeeded(for: episode)
                            }
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .ignoresSafeArea()
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
                            .esaForeground(.secondary)
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
        .padding(.top, 0)
        .navigationTitle(viewModel.podcastFeed.title ?? "Browse Episodes")
        .task {
            await viewModel.loadInitialPageIfNeeded()
        }
        .onAppear {
            Task { await viewModel.refreshSubscriptionStatus() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await viewModel.refreshSubscriptionStatus() }
        }
        .refreshable {
            await viewModel.reload()
        }
        .ESAFullBackground(image: viewModel.podcastFeed.artworkURL)
    }
}

private struct PodcastBrowseHeaderView: View {
    let feed: PodcastFeed
    let isSubscribed: Bool
    let isSubscribing: Bool
    let showsLiveMetadata: Bool
    let subscribeAction: () async -> Void
    let alternativeFeedAction: (PodcastAlternativeFeed) async -> Void
    @Environment(\.deviceUIStyle) var style
    @State private var isDetailsExpanded = false

    private var availableAlternativeFeeds: [PodcastAlternativeFeed] {
        feed.alternativeFeeds.filter { $0.url != feed.url }
    }

    private var lastUpdatedText: String? {
        feed.lastRelease?.formatted(date: .numeric, time: .shortened)
    }

    private var lastRefreshText: String? {
        feed.importedLastRefresh?.formatted(date: .numeric, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                            .esaForeground(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            DisclosureGroup(isExpanded: $isDetailsExpanded) {
                if isDetailsExpanded {
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

                    PodcastValueSplitView(optionalTags: feed.optionalTags, funding: feed.funding)

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
                        PodcastNamespaceMetadataView(
                            optionalTags: optionalTags,
                            title: "Podcast Metadata",
                            hidesRenderableValueBlocks: true,
                            showsLiveMetadata: showsLiveMetadata
                        )
                        .padding()
                    }

                    if let description = feed.description, description.isEmpty == false {
                        ShownoteContentView(html: description)
                            .padding()
                    }

                    if let link = feed.link {
                        Link(destination: link) {
                            Label("Open in Browser", systemImage: "safari")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.glass(.clear))
                    }
                    }
                }
            } label: {
                Label("Podcast details", systemImage: "info.circle")
            }

            if availableAlternativeFeeds.isEmpty == false {
                Menu {
                    ForEach(availableAlternativeFeeds) { alternativeFeed in
                        Button {
                            Task {
                                await alternativeFeedAction(alternativeFeed)
                            }
                        } label: {
                            Label(alternativeFeed.displayTitle, systemImage: "dot.radiowaves.left.and.right")
                        }
                    }
                } label: {
                    Label("Subscribe to Alternative Feed", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.glass(.clear))
                .disabled(isSubscribing)
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

            Text("This feed stays transient until you play or queue an episode. Subscribing stays optional.")
                .font(.caption)
                .esaForeground(.secondary)
        }
    }
}

private struct PodcastBrowseEpisodeRowView: View, @preconcurrency Equatable {
    let episode: PodcastEpisodeDraft
    let podcastFeed: PodcastFeed
    let isSubscribed: Bool
    let isPlaying: Bool
    let queueAction: (Playlist.Position) async -> Bool
    let playAction: () async -> Bool
    let prepareAction: () async throws -> URL
    let subscribeAction: () async -> Bool

    @State private var isQueueing = false
    @State private var isStartingPlayback = false
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 210
    @ScaledMetric(relativeTo: .body) private var artworkSize: CGFloat = 120
    @ScaledMetric(relativeTo: .body) private var controlsHeight: CGFloat = 50

    static func == (lhs: PodcastBrowseEpisodeRowView, rhs: PodcastBrowseEpisodeRowView) -> Bool {
        lhs.episode.id == rhs.episode.id
            && lhs.episode.title == rhs.episode.title
            && lhs.episode.desc == rhs.episode.desc
            && lhs.episode.content == rhs.episode.content
            && lhs.episode.publishDate == rhs.episode.publishDate
            && lhs.episode.episodeURL == rhs.episode.episodeURL
            && lhs.episode.imageURL == rhs.episode.imageURL
            && lhs.episode.duration == rhs.episode.duration
            && lhs.episode.type == rhs.episode.type
            && lhs.episode.deeplinks == rhs.episode.deeplinks
            && lhs.podcastFeed.previewRefreshID == rhs.podcastFeed.previewRefreshID
            && lhs.isSubscribed == rhs.isSubscribed
            && lhs.isPlaying == rhs.isPlaying
    }

    private var displayTime: String {
        let duration = episode.duration ?? 0
        return Duration.seconds(duration).formatted(.units(width: .narrow))
    }

    private var publishText: String {
        episode.publishDate?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown Date"
    }

    private var episodeTypeBadgeText: String? {
        switch episode.type {
        case .trailer:
            return "Trailer"
        case .bonus:
            return "Bonus"
        case .full, .unknown, nil:
            return nil
        }
    }

    private func startQueue(_ position: Playlist.Position) {
        guard isQueueing == false, isStartingPlayback == false else { return }
        isQueueing = true
        Task {
            _ = await queueAction(position)
            await MainActor.run {
                isQueueing = false
            }
        }
    }

    private func startPlayback() {
        guard isQueueing == false, isStartingPlayback == false else { return }
        isStartingPlayback = true
        Task {
            _ = await playAction()
            isStartingPlayback = false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
                NavigationLink {
                    PodcastBrowseEpisodeDetailView(
                        episode: episode,
                        podcastFeed: podcastFeed,
                        isSubscribed: isSubscribed,
                        queueAction: queueAction,
                        playAction: playAction,
                        prepareAction: prepareAction,
                        subscribeAction: subscribeAction
                    )
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                    ZStack {
        CoverImageView(imageURL: episode.imageURL ?? podcastFeed.artworkURL, maxPixelSize: 384)
                            .frame(width: artworkSize, height: artworkSize)
                            .accessibilityHidden(true)

                        if let episodeTypeBadgeText {
                            Text(episodeTypeBadgeText)
                                .font(.caption2.weight(.semibold))
                                .esaForeground(.primary)
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(6)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .accessibilityLabel("Episode type: \(episodeTypeBadgeText)")
                        }
                    }
                    .frame(width: artworkSize, height: artworkSize)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            Text(podcastFeed.title ?? "Untitled Podcast")
                                .font(.caption)
                                .esaForeground(.secondary)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            Text(publishText)
                                .font(.caption)
                                .esaForeground(.secondary)
                        }

                        Text(episode.title)
                            .font(.headline)
                            .lineLimit(4)
                            .esaForeground(.primary)

                        Spacer(minLength: 0)

                        Text(displayTime)
                            .font(.caption)
                            .esaForeground(.secondary)

                        HStack(spacing: 10) {
                            Image(systemName: "cloud")
                                .accessibilityLabel("Not downloaded")

                            if episode.content != nil {
                                Image(systemName: "quote.bubble")
                                    .accessibilityLabel("Has content")
                            }

                            if episode.deeplinks.isEmpty == false {
                                Image(systemName: "link")
                                    .accessibilityLabel("Has links")
                            }

                            Spacer()
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, minHeight: artworkSize, alignment: .topLeading)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens episode details")

                HStack {
                    Button {
                        startPlayback()
                    } label: {
                        if isPlaying || isStartingPlayback {
                            ProgressView()
                                .frame(width: 50, height: 50)
                        } else {
                            Label("Play", systemImage: "play.fill")
                                .symbolRenderingMode(.hierarchical)
                                .scaledToFit()
                                .esaForeground(.control)
                                .padding(5)
                                .minimumScaleFactor(0.5)
                                .labelStyle(.iconOnly)
                                .clipShape(Circle())
                                .frame(width: 50)
                        }
                    }
                    .buttonStyle(.glass(.clear))
                    .accessibilityLabel("Play episode")
                    .accessibilityHint("Starts this episode immediately")
                    .disabled(isQueueing || isStartingPlayback)

                    Spacer()

                    GlassEffectContainer(spacing: 20.0) {
                        HStack(spacing: 0.0) {
                            Button {
                                startQueue(.front)
                            } label: {
                                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                    .labelStyle(.iconOnly)
                                    .symbolRenderingMode(.hierarchical)
                                    .esaForeground(.control)
                                    .scaledToFit()
                                    .padding(5)
                                    .minimumScaleFactor(0.5)
                                    .frame(width: 50)
                            }
                            .buttonStyle(.glass(.clear))
                            .clipShape(Circle())
                            .disabled(isQueueing || isStartingPlayback)
                            .accessibilityLabel("Add to Up Next")

                            Button {
                                startQueue(.end)
                            } label: {
                                Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
                                    .labelStyle(.iconOnly)
                                    .symbolRenderingMode(.hierarchical)
                                    .esaForeground(.control)
                                    .scaledToFit()
                                    .padding(5)
                                    .minimumScaleFactor(0.5)
                                    .frame(width: 50)
                            }
                            .buttonStyle(.glass(.clear))
                            .clipShape(Circle())
                            .disabled(isQueueing || isStartingPlayback)
                            .accessibilityLabel("Add to End")
                        }
                    }

                    Spacer()
                }
                .frame(minHeight: controlsHeight)
            }
        .ESA_RowView(image: episode.imageURL ?? podcastFeed.artworkURL, minHeight: rowHeight)
        .overlay(alignment: .bottomLeading) {
            Rectangle()
                .fill(Color.accent.opacity(0.18))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: 4)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

private struct PodcastBrowseEpisodeDetailView: View {
    let episode: PodcastEpisodeDraft
    let podcastFeed: PodcastFeed
    let queueAction: (Playlist.Position) async -> Bool
    let playAction: () async -> Bool
    let prepareAction: () async throws -> URL
    let subscribeAction: () async -> Bool

    @Environment(\.deviceUIStyle) private var style
    @Environment(\.modelContext) private var modelContext
    @State private var isQueueing = false
    @State private var isSubscribing = false
    @State private var isPlaying = false
    @State private var isPreparingDownload = false
    @State private var isSubscribed: Bool
    @State private var actionError: String?
    @State private var materializedEpisode: Episode?

    init(
        episode: PodcastEpisodeDraft,
        podcastFeed: PodcastFeed,
        isSubscribed: Bool,
        queueAction: @escaping (Playlist.Position) async -> Bool,
        playAction: @escaping () async -> Bool,
        prepareAction: @escaping () async throws -> URL,
        subscribeAction: @escaping () async -> Bool
    ) {
        self.episode = episode
        self.podcastFeed = podcastFeed
        self.queueAction = queueAction
        self.playAction = playAction
        self.prepareAction = prepareAction
        self.subscribeAction = subscribeAction
        self._isSubscribed = State(initialValue: isSubscribed)
    }

    private var funding: [FundingInfo] {
        (episode.rawEpisodeData["funding"] as? [[String: String]] ?? []).compactMap { item in
            guard let urlText = item["url"],
                  let label = item["label"],
                  let url = URL(string: urlText, relativeTo: podcastFeed.url)?.absoluteURL
            else { return nil }
            return FundingInfo(url: url, label: label)
        }
    }

    private var optionalTags: PodcastNamespaceOptionalTags? {
        episode.rawEpisodeData["optionalTags"] as? PodcastNamespaceOptionalTags
    }

    private var externalFiles: [ExternalFile] {
        (episode.rawEpisodeData["externalFiles"] as? [ExternalFile])
            ?? (episode.rawEpisodeData["transcripts"] as? [ExternalFile])
            ?? []
    }

    private var chapters: [[String: Any]] {
        episode.rawEpisodeData["psc:chapters"] as? [[String: Any]] ?? []
    }

    private var enclosure: [String: Any]? {
        EpisodeMedia.playableEnclosure(from: episode.rawEpisodeData["enclosure"] as? [[String: Any]])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    CoverImageView(imageURL: episode.imageURL ?? podcastFeed.artworkURL)
                        .frame(width: 104, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(podcastFeed.title ?? "Untitled Podcast")
                            .font(.subheadline)
                            .esaForeground(.secondary)
                        Text(episode.title)
                            .font(.title2.weight(.bold))
                        if let date = episode.publishDate {
                            Label(date.formatted(date: .long, time: .omitted), systemImage: "calendar")
                                .font(.caption)
                                .esaForeground(.secondary)
                        }
                        if let duration = episode.duration {
                            Label(Duration.seconds(duration).formatted(.units(width: .abbreviated)), systemImage: "clock")
                                .font(.caption)
                                .esaForeground(.secondary)
                        }
                    }
                }

                HStack {
                    if let materializedEpisode {
                        DownloadControllView(episode: materializedEpisode, showDelete: false)
                            .frame(width: 50, height: 50)
                    } else {
                        Button {
                            prepareDownload()
                        } label: {
                            if isPreparingDownload {
                                ProgressView()
                                    .frame(width: 50, height: 50)
                            } else {
                                Label("Download", systemImage: "arrow.down.circle")
                                    .labelStyle(.iconOnly)
                                    .symbolRenderingMode(.hierarchical)
                                    .esaForeground(.control)
                                    .frame(width: 50, height: 50)
                            }
                        }
                        .buttonStyle(.glass(.clear))
                        .accessibilityLabel("Download episode")
                        .accessibilityHint("Downloads this episode for offline playback")
                        .disabled(isPreparingDownload)
                    }

                    Spacer()

                    Button {
                        startPlayback()
                    } label: {
                        if isPlaying {
                            ProgressView()
                                .frame(width: 50, height: 50)
                        } else {
                            Label("Play", systemImage: "play.fill")
                                .symbolRenderingMode(.hierarchical)
                                .scaledToFit()
                                .esaForeground(.control)
                                .padding(5)
                                .minimumScaleFactor(0.5)
                                .labelStyle(.iconOnly)
                                .clipShape(Circle())
                                .frame(width: 50)
                        }
                    }
                    .buttonStyle(.glass(.clear))
                    .accessibilityLabel("Play episode")
                    .accessibilityHint("Starts this episode immediately")
                    .disabled(isQueueing || isPlaying)

                    Spacer()

                    GlassEffectContainer(spacing: 20.0) {
                        HStack(spacing: 0.0) {
                            Button {
                                queue(.front)
                            } label: {
                                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                    .labelStyle(.iconOnly)
                                    .symbolRenderingMode(.hierarchical)
                                    .esaForeground(.control)
                                    .scaledToFit()
                                    .padding(5)
                                    .minimumScaleFactor(0.5)
                                    .frame(width: 50)
                            }
                            .buttonStyle(.glass(.clear))
                            .clipShape(Circle())
                            .disabled(isQueueing || isPlaying)
                            .accessibilityLabel("Add to Up Next")

                            Button {
                                queue(.end)
                            } label: {
                                Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
                                    .labelStyle(.iconOnly)
                                    .symbolRenderingMode(.hierarchical)
                                    .esaForeground(.control)
                                    .scaledToFit()
                                    .padding(5)
                                    .minimumScaleFactor(0.5)
                                    .frame(width: 50)
                            }
                            .buttonStyle(.glass(.clear))
                            .clipShape(Circle())
                            .disabled(isQueueing || isPlaying)
                            .accessibilityLabel("Add to End")
                        }
                    }

                }
                .frame(minHeight: 50)

                Button {
                    subscribe()
                } label: {
                    Label(
                        isSubscribed ? "Subscribed" : "Subscribe to Podcast",
                        systemImage: isSubscribed ? "checkmark.circle.fill" : "plus.circle"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(isSubscribed || isSubscribing)

                if let actionError {
                    Text(actionError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if funding.isEmpty == false {
                    HStack {
                        ForEach(funding) { item in
                            Link(destination: item.url) {
                                Label(item.label, systemImage: style.currencySFSymbolName)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                PodcastValueSplitView(
                    optionalTags: optionalTags,
                    funding: funding.isEmpty ? podcastFeed.funding : funding
                )
                PodcastNamespaceMetadataView(
                    optionalTags: optionalTags,
                    title: "Episode Metadata",
                    hidesRenderableValueBlocks: true
                )

                if let showNotes = episode.content ?? episode.desc, showNotes.isEmpty == false {
                    ShownoteContentView(html: showNotes)
                }

                if chapters.isEmpty == false {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Chapters")
                            .font(.headline)
                        ForEach(Array(chapters.enumerated()), id: \.offset) { item in
                            let chapter = item.element
                            HStack(alignment: .firstTextBaseline) {
                                Text(chapterStartText(chapter["start"]))
                                    .font(.caption.monospacedDigit())
                                    .esaForeground(.secondary)
                                Text(chapter["title"] as? String ?? "Chapter")
                            }
                        }
                    }
                }

                if externalFiles.isEmpty == false {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Episode Files")
                            .font(.headline)
                        ForEach(Array(externalFiles.enumerated()), id: \.offset) { item in
                            let file = item.element
                            if let url = URL(string: file.url) {
                                Link(destination: url) {
                                    Label(file.category == .transcript ? "Transcript" : "Episode File", systemImage: "doc.text")
                                }
                            }
                        }
                    }
                }

                if let enclosure {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Media")
                            .font(.headline)
                        if let type = enclosure["type"] as? String {
                            LabeledContent("Format", value: type)
                        }
                        if let length = Int64(enclosure["length"] as? String ?? ""), length > 0 {
                            LabeledContent("File size", value: ByteCountFormatter.string(fromByteCount: length, countStyle: .file))
                        }
                        Link(destination: episode.episodeURL) {
                            Label("Open Episode Media", systemImage: "arrow.up.right.square")
                        }
                    }
                }

                HStack {
                    if let link = episode.link {
                        Link(destination: link) {
                            Label("Episode Website", systemImage: "safari")
                        }
                    }
                    if let link = podcastFeed.link {
                        Link(destination: link) {
                            Label("Podcast Website", systemImage: "globe")
                        }
                    }
                    Spacer()
                    ShareLink(item: episode.link ?? episode.episodeURL) {
                        Label("Share Episode", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass(.clear))
                    .accessibilityLabel("Share episode")
                }

                ForEach(episode.deeplinks, id: \.self) { link in
                    Link(destination: link) {
                        Label(link.host ?? "Open Episode Link", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .padding()
        }
        .coverHero(image: .url(episode.imageURL ?? podcastFeed.artworkURL), title: episode.title)
        .ESAFullBackground(image: episode.imageURL ?? podcastFeed.artworkURL)
        .navigationTitle(episode.title)
        .platformInlineNavigationTitle()
    }

    private func queue(_ position: Playlist.Position) {
        guard isQueueing == false else { return }
        isQueueing = true
        Task {
            let succeeded = await queueAction(position)
            if succeeded == false {
                actionError = position == .front
                    ? "Could not add this episode to Up Next."
                    : "Could not add this episode to the end of the playlist."
            } else {
                await refreshMaterializedEpisode()
            }
            isQueueing = false
        }
    }

    private func startPlayback() {
        guard isPlaying == false else { return }
        isPlaying = true
        Task {
            let succeeded = await playAction()
            if succeeded == false {
                actionError = "Could not start this episode."
            } else {
                await refreshMaterializedEpisode()
            }
            isPlaying = false
        }
    }

    private func prepareDownload() {
        guard isPreparingDownload == false else { return }
        isPreparingDownload = true
        Task {
            do {
                let episodeURL = try await prepareAction()
                materializedEpisode = try fetchMaterializedEpisode(at: episodeURL)
            } catch {
                actionError = error.localizedDescription
            }
            isPreparingDownload = false
        }
    }

    private func refreshMaterializedEpisode() async {
        guard let episodeURL = try? await prepareAction() else { return }
        materializedEpisode = try? fetchMaterializedEpisode(at: episodeURL)
    }

    private func fetchMaterializedEpisode(at episodeURL: URL) throws -> Episode {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { $0.url == episodeURL }
        )
        guard let episode = try modelContext.fetch(descriptor).first else {
            throw PodcastBrowseEpisodeActionError.episodeUnavailable
        }
        return episode
    }

    private func subscribe() {
        guard isSubscribing == false else { return }
        isSubscribing = true
        Task {
            let succeeded = await subscribeAction()
            isSubscribing = false
            isSubscribed = succeeded
            if succeeded == false {
                actionError = "Could not subscribe to this podcast."
            }
        }
    }

    private func chapterStartText(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? Double {
            return Duration.seconds(value).formatted(.time(pattern: .minuteSecond))
        }
        return ""
    }
}

private enum PodcastBrowseEpisodeActionError: LocalizedError {
    case episodeUnavailable

    var errorDescription: String? {
        "This episode is no longer available."
    }
}
