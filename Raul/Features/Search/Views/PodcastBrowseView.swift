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
            let episodeURL = try await SubscriptionManager(modelContainer: modelContainer)
                .prepareBrowseEpisodeForPlayback(episode, from: podcastFeed)
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
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func loadAlternativeFeed(_ alternativeFeed: PodcastAlternativeFeed) async {
        guard isLoading == false, isSubscribing == false else { return }

        let replacementFeed = PodcastFeed(
            url: alternativeFeed.url,
            title: alternativeFeed.title,
            source: podcastFeed.source,
            accessCredential: podcastFeed.accessCredential,
            accessKind: podcastFeed.accessKind,
            fetchMetadataIfNeeded: false
        )
        podcastFeed = replacementFeed
        await reload()
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
            let document = try await PodcastParser.downloadFeed(from: url, profile: accessProfile)
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
                mergedFeed.accessCredential = podcastFeed.accessCredential
                mergedFeed.accessKind = podcastFeed.accessKind
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

    init(feed: PodcastFeed, modelContainer: ModelContainer) {
        _viewModel = StateObject(wrappedValue: PodcastBrowseViewModel(feed: feed, modelContainer: modelContainer))
    }

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .esaForeground(.secondary)
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
                            subscribeAction: {
                                await viewModel.subscribe()
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
                            .esaForeground(.secondary)
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

private struct PodcastBrowseEpisodeRowView: View {
    let episode: PodcastEpisodeDraft
    let podcastFeed: PodcastFeed
    let isSubscribed: Bool
    let isPlaying: Bool
    let queueAction: (Playlist.Position) async -> Bool
    let playAction: () async -> Bool
    let subscribeAction: () async -> Bool

    @State private var isQueueing = false
    @State private var isStartingPlayback = false
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 210
    @ScaledMetric(relativeTo: .body) private var artworkSize: CGFloat = 120
    @ScaledMetric(relativeTo: .body) private var controlsHeight: CGFloat = 50

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
                        subscribeAction: subscribeAction
                    )
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        CoverImageView(imageURL: episode.imageURL ?? podcastFeed.artworkURL)
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

                GlassEffectContainer(spacing: 20.0) {
                    HStack(spacing: 0.0) {
                        Button {
                            startQueue(.front)
                        } label: {
                            Label("Add to Up Next", systemImage: "arrow.up.to.line")
                                .labelStyle(.iconOnly)
                                .symbolRenderingMode(.hierarchical)
                                .scaledToFit()
                                .padding(5)
                                .minimumScaleFactor(0.5)
                                .frame(width: 50)
                        }
                        .buttonStyle(.glass(.clear))
                        .clipShape(Circle())
                        .disabled(isQueueing || isStartingPlayback)

                        Button {
                            startQueue(.end)
                        } label: {
                            Label("Add to End", systemImage: "arrow.down.to.line")
                                .labelStyle(.iconOnly)
                                .symbolRenderingMode(.hierarchical)
                                .scaledToFit()
                                .padding(5)
                                .minimumScaleFactor(0.5)
                                .frame(width: 50)
                        }
                        .buttonStyle(.glass(.clear))
                        .clipShape(Circle())
                        .disabled(isQueueing || isStartingPlayback)

                        Button {
                            startPlayback()
                        } label: {
                            if isPlaying || isStartingPlayback {
                                ProgressView()
                                    .frame(width: 50, height: 50)
                            } else {
                                Label("Play Episode", systemImage: "play.fill")
                                    .labelStyle(.iconOnly)
                                    .symbolRenderingMode(.hierarchical)
                                    .scaledToFit()
                                    .padding(5)
                                    .minimumScaleFactor(0.5)
                                    .frame(width: 50)
                            }
                        }
                        .buttonStyle(.glass(.clear))
                        .clipShape(Circle())
                        .disabled(isQueueing || isStartingPlayback)
                        .accessibilityLabel("Play Episode")

                        Spacer()

                        if isQueueing {
                            ProgressView()
                        }
                    }
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
    let subscribeAction: () async -> Bool

    @Environment(\.deviceUIStyle) private var style
    @State private var isQueueing = false
    @State private var isSubscribing = false
    @State private var isSubscribed: Bool
    @State private var actionError: String?

    init(
        episode: PodcastEpisodeDraft,
        podcastFeed: PodcastFeed,
        isSubscribed: Bool,
        queueAction: @escaping (Playlist.Position) async -> Bool,
        subscribeAction: @escaping () async -> Bool
    ) {
        self.episode = episode
        self.podcastFeed = podcastFeed
        self.queueAction = queueAction
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

                HStack(spacing: 14) {
                    Button {
                        queue(.front)
                    } label: {
                        Label("Add to Up Next", systemImage: "arrow.up.to.line")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isQueueing)

                    Button {
                        queue(.end)
                    } label: {
                        Label("Add to End", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isQueueing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

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
                actionError = "Could not add this episode to Up Next."
            }
            isQueueing = false
        }
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
