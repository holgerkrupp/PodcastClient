//
//  EpisodeView.swift
//  Raul
//
//  Created by Holger Krupp on 05.05.25.
//

import SwiftUI
import SwiftData
import ESADesignKit

struct PodcastDetailView: View {
    @Environment(\.esaArtworkBlurLevel) private var artworkBlurLevel
    private static let episodePageSize = 80

    enum EpisodeSortOption: String, CaseIterable, Identifiable {
        case newestFirst
        case oldestFirst
        case titleAZ
        case titleZA

        var id: String { rawValue }

        var label: String {
            switch self {
            case .newestFirst: return "Newest First"
            case .oldestFirst: return "Oldest First"
            case .titleAZ:     return "Title A–Z"
            case .titleZA:     return "Title Z–A"
            }
        }

    }

    
    @Bindable var podcast: Podcast
    private enum SubscriptionOperationState: Equatable {
        case idle
        case committing(Bool)
    }

    @State private var isLoading = false
    @State private var isSwitchingAlternativeFeed = false
    @State private var showFeedRepair = false
    @State private var showAuthenticationEditor = false
    @State private var refreshProgress: Double = 0
    @State private var refreshProgressMessage: String?
    @State private var errorMessage: String?
    @State private var isFilteringEpisodes = false
    @State private var subscriptionErrorMessage: String?
    @State private var subscriptionOperation: SubscriptionOperationState = .idle
    @State private var confirmedSubscriptionState: Bool?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.deviceUIStyle) var style
    @Environment(\.openPodcastSettings) private var openSettings
    @Query(filter: PodcastSettingsView.defaultSettingsFilter) private var defaultSettings: [PodcastSettings]

    @State private var showPodroll: Bool = false
    @State private var showTranscriptSearch = false
    @State private var hasSearchableTranscripts = false
    @State private var showDebugMetadata: Bool = false
    @State private var predictedReleaseFrequencyLabel: String?
#if DEBUG
    @State private var predictedReleaseDate: Date?
#endif
    @State private var liveNotificationMessage: String?
    @State private var hasAttemptedInitialFeedImport = false
    @State private var podcastHasEpisodes = true
    @AppStorage("EpisodeSortOption") private var sortOptionRawValue: String = EpisodeSortOption.newestFirst.rawValue
    private var sortOption: EpisodeSortOption {
        get { EpisodeSortOption(rawValue: sortOptionRawValue) ?? .newestFirst }
        set { sortOptionRawValue = newValue.rawValue }
    }
    
    @State private var searchText = ""
    @State private var searchInTitle = true
    @State private var searchInAuthor = false
    @State private var searchInDescription = true
    @State private var searchInTranscript = true
    @State private var filteredEpisodes: [Episode] = []
    @State private var filteredEpisodeIDs: [PersistentIdentifier] = []
    @State private var filteredEpisodeURLs: [URL?] = []
    @State private var filteredEpisodeDisplayLimit = Self.episodePageSize
    @State private var episodeFilterTask: Task<Void, Never>?
    @AppStorage("HidePlayedAndArchived") private var hidePlayedAndArchived: Bool = false

    private var availableAlternativeFeeds: [PodcastAlternativeFeed] {
        podcast.alternativeFeeds.filter { $0.url != podcast.feed }
    }

    private var podcastTrailers: [PodcastTrailer] {
        podcast.optionalTags?.podcastTrailers(baseURL: podcast.feed) ?? []
    }

    private var podrollItems: [PodcastPodrollItem] {
        podcast.optionalTags?.podcastPodrollItems(baseURL: podcast.feed) ?? []
    }

    private var liveItems: [PodcastLiveItem] {
        podcast.liveItems
    }

    private var visibleFilteredEpisodes: [Episode] {
        Array(filteredEpisodes.prefix(filteredEpisodeDisplayLimit))
    }

    private var needsInitialFeedImport: Bool {
        displayedIsSubscribed
            && podcast.feed != nil
            && podcast.metaData?.lastRefresh == nil
            && podcastHasEpisodes == false
    }

    private var displayedIsSubscribed: Bool {
        confirmedSubscriptionState ?? podcast.isSubscribed
    }

    private var identityPresentation: PodcastRowPresentation {
        PodcastRowPresentation(
            identity: podcast.stablePodcastIdentityKey,
            feedURL: podcast.feed,
            title: podcast.title,
            author: podcast.author,
            summary: podcast.desc,
            artworkURL: podcast.imageURL,
            status: displayedIsSubscribed ? .subscribed : .notSubscribed
        )
    }

    private var subscriptionControls: some View {
        Button {
            guard displayedIsSubscribed == false else { return }
            Task { await toggleSubscriptionStatus() }
        } label: {
            Group {
                switch subscriptionOperation {
                case .committing(let targetState):
                    ProgressView()
                        .accessibilityLabel(targetState ? "Subscribing" : "Unsubscribing")
                case .idle:
                    if displayedIsSubscribed {
                        Label("Subscribed", systemImage: "checkmark.circle.fill")
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    } else {
                        Label("Subscribe", systemImage: "plus.circle.fill")
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
        }
        .buttonStyle(.glass(.clear))
        .disabled(displayedIsSubscribed || subscriptionOperation != .idle)
        .accessibilityIdentifier("podcast-detail-subscription-button")
    }

    private var transcriptSearchControl: some View {
        Button {
            showTranscriptSearch = true
        } label: {
            Label("Search Transcripts", systemImage: "text.magnifyingglass")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
        }
        .buttonStyle(.glass(.clear))
        .accessibilityHint("Searches every locally available transcript in this podcast")
    }

    private var headerActionControls: some View {
        HStack(spacing: 10) {
            subscriptionControls
            if hasSearchableTranscripts {
                transcriptSearchControl
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

#if DEBUG
    private var displayedPredictedReleaseDate: Date? {
        podcast.metaData?.nextPredictedReleaseDate ?? predictedReleaseDate
    }
#endif

    private var abandonedFeedCard: some View {
        PodcastAbandonedFeedCard(metadata: podcast.metaData)
    }

    private var needsAuthenticationRepair: Bool {
        podcast.metaData?.credentialState == .needsLogin
            || podcast.metaData?.credentialState == .storageUnavailable
            || (podcast.feed?.isLikelyPrivatePodcastURL == true
                && podcast.metaData?.credentialState == .missing)
    }

    private var authenticationRepairCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Authentication required", systemImage: "lock.fill")
                .font(.headline)
            Text("This podcast needs credentials to download new episodes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Fix Authentication") {
                showAuthenticationEditor = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("podcast-detail-fix-authentication")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    private var currentLiveItem: PodcastLiveItem? {
        liveItems.first { $0.status == .live }
    }

    private var nextLiveItem: PodcastLiveItem? {
        liveItems
            .filter(\.isUpcoming)
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
            .first
    }

    private var liveItemNotificationsEnabled: Bool {
        guard defaultSettings.first?.enableLiveItemNotifications != false else {
            return false
        }

        guard podcast.settings?.isEnabled == true else {
            return true
        }

        return podcast.settings?.enableLiveItemNotifications != false
    }

    private var isLiveNotificationPresented: Binding<Bool> {
        Binding(
            get: { liveNotificationMessage != nil },
            set: { isPresented in
                if isPresented == false {
                    liveNotificationMessage = nil
                }
            }
        )
    }

    private var refreshProgressCard: some View {
        let progress = max(refreshProgress, 0.02)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                Text(refreshProgressMessage ?? "Refreshing podcast")
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                Text(refreshProgress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .esaForeground(.secondary)
            }

            ProgressView(value: progress, total: 1)
                .tint(.accentColor)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
        }
    }

    
    init(podcast: Podcast) {
        self._podcast = Bindable(wrappedValue: podcast)
    }
    
  
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        CoverImageView(podcast: podcast)
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(podcast.title)
                                .font(.title3.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)

                            if let author = podcast.author, author.isEmpty == false {
                                Text(author)
                                    .font(.subheadline)
                                    .esaForeground(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if let summary = identityPresentation.summary {
                                Text(summary)
                                    .font(.caption)
                                    .esaForeground(.secondary)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            let metadataChips = PodcastDetailMetadataChipsView(podcast: podcast)
                            if metadataChips.hasContent {
                                metadataChips
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let podcastLink = podcast.link {
                            Link(destination: podcastLink) {
                                Label("Open podcast website", systemImage: "safari")
                                    .labelStyle(.iconOnly)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.glass(.clear))
                            .accessibilityLabel("Open podcast website")
                        }
                    }

                    if isLoading {
                        refreshProgressCard
                    }

                    if needsAuthenticationRepair {
                        authenticationRepairCard
                    }

                    abandonedFeedCard

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let subscriptionErrorMessage {
                        Label(subscriptionErrorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if displayedIsSubscribed == false {
                        Text("This podcast stays in your library but is skipped by bulk refresh until you subscribe.")
                            .font(.caption)
                            .esaForeground(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    headerActionControls

                    if showLivePodcasts && (currentLiveItem != nil || (nextLiveItem != nil && liveItemNotificationsEnabled)) {
                        PodcastLiveItemControlsView(
                            currentLiveItem: currentLiveItem,
                            nextLiveItem: nextLiveItem,
                            liveItemNotificationsEnabled: liveItemNotificationsEnabled,
                            podcastTitle: podcast.title,
                            artworkURL: podcast.imageURL
                        ) { liveItem in
                            Task {
                                await scheduleLiveNotification(for: liveItem)
                            }
                        }
                    }
                }
                .fullPageScreenshotSupport()
                .overlay {
                    if let message = podcast.message {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(message)
                                .font(.headline)
                        }
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .frame(maxWidth: 300)
                    }
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            Section {
                if visibleFilteredEpisodes.isEmpty {
                    if isLoading || isFilteringEpisodes {
                        ProgressView("Loading episodes…")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else if searchText.isEmpty == false {
                        ContentUnavailableView.search(text: searchText)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else {
                        ContentUnavailableView(
                            "No Episodes Yet",
                            systemImage: "dot.radiowaves.left.and.right",
                            description: Text("Refresh the podcast to check for episodes.")
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(visibleFilteredEpisodes, id: \.persistentModelID) { episode in
                        ZStack {
                            EpisodeRowView(episode: episode)
                            NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                                EmptyView()
                            }.opacity(0)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open episode \(episode.title)")
                        .accessibilityHint("Opens this episode details screen")
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .task {
                            await Task.yield()
                            guard Task.isCancelled == false else { return }
                            loadMoreEpisodesIfNeeded(currentEpisode: episode)
                        }
                    }
                    .onDelete { indexSet in
                        Task {
                            for index in indexSet {
                                let episodeID = filteredEpisodes[index].persistentModelID
                                try? await PodcastModelActor(modelContainer: modelContext.container)
                                    .deleteEpisode(episodeID)
                            }
                        }
                    }
                }
            } header: {
                Text("Episodes")
            }
            .listRowSeparator(.hidden)

            Section {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        if let predictedReleaseFrequencyLabel {
                            Label("Release schedule: \(predictedReleaseFrequencyLabel)", systemImage: "calendar")
                                .font(.caption)
                                .esaForeground(.secondary)
                        }

                        HStack {
                            if let lastBuildDate = podcast.lastBuildDate {
                                Text("Last updated: \(lastBuildDate.formatted(date: .numeric, time: .shortened))")
                                    .font(.caption2)
                                    .esaForeground(.secondary)
                            }
                            Spacer()
                        if let lastRefreshDate = podcast.metaData?.feedUpdateCheckDate {
                            Text("Last checked: \(lastRefreshDate.formatted(date: .numeric, time: .shortened))")
                                .font(.caption2)
                                .esaForeground(.secondary)
                        }
                        }

                        if let metadata = podcast.metaData {
                            VStack(alignment: .leading, spacing: 8) {
                                if let status = metadata.feedFailureStatusDescription {
                                    LabeledContent("Last feed response", value: status)
                                }
                                if let failedAt = metadata.lastFeedFailureDate {
                                    LabeledContent("Last failed check") {
                                        Text(failedAt.formatted(date: .abbreviated, time: .shortened))
                                    }
                                }
                                if metadata.consecutiveFeedFailureCount > 0 {
                                    LabeledContent("Consecutive failures") {
                                        Text("\(metadata.consecutiveFeedFailureCount)")
                                            .monospacedDigit()
                                    }
                                }
                                if let failure = metadata.lastFeedFailureMessage, failure.isEmpty == false {
                                    Text(failure)
                                        .font(.caption2)
                                        .esaForeground(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .font(.caption)
                        }

#if DEBUG
                        Text(
                            displayedPredictedReleaseDate.map {
                                "Next predicted release: \($0.formatted(date: .abbreviated, time: .shortened))"
                            } ?? "Next predicted release: Unavailable"
                        )
                        .font(.caption2.monospacedDigit())
                        .esaForeground(.secondary)
#endif

                        if podcastTrailers.isEmpty == false {
                            PodcastTrailerButton(
                                trailers: podcastTrailers,
                                podcastTitle: podcast.title,
                                artworkURL: podcast.imageURL
                            )
                        }

                        if podrollItems.isEmpty == false {
                            Button {
                                showPodroll = true
                            } label: {
                                Label("Podroll", systemImage: "rectangle.connected.to.line.below")
                            }
                            .buttonStyle(.glass(.clear))
                            .accessibilityHint("Shows podcasts recommended by this podcast")
                        }

                        if podcast.funding.isEmpty == false {
                            ForEach(podcast.funding) { fund in
                                Link(destination: fund.url) {
                                    Label(fund.label, systemImage: style.currencySFSymbolName)
                                }
                            }
                        }

                        PodcastValueSplitView(optionalTags: podcast.optionalTags, funding: podcast.funding)

                        if let copyright = podcast.copyright {
                            Text(copyright)
                                .font(.caption)
                                .esaForeground(.secondary)
                        }

                        PodcastDetailMetadataSections(
                            podcast: podcast,
                            showsLiveMetadata: showLivePodcasts
                        )
                    }
                    .padding(.top, 8)
                } label: {
                    Label("About & Podcast Details", systemImage: "info.circle")
                }
            }
            .listRowSeparator(.hidden)
        }
        .coverHero(
            image: .url(podcast.imageURL),
            title: podcast.title,
            material: artworkBlurLevel.detailMaterial
        )
        .ESAFullBackground(image: podcast.imageURL)
        .listStyle(.plain)
        .padding(.top, 0)
        .navigationTitle(podcast.title)
        .platformInlineNavigationTitle()
        .searchable(text: $searchText)
        .task {
            SystemPressureGate.shared.noteUserInteraction()
            applyEpisodeFilters()
            let filterActor = PodcastEpisodeFilterActor(modelContainer: modelContext.container)
            podcastHasEpisodes = (try? await filterActor.hasEpisodes(
                podcastID: podcast.persistentModelID
            )) ?? true
            await updatePredictedReleaseInfo()
            await refreshEpisodesIfNeeded()
            await updatePredictedReleaseInfo()
        }
        .onAppear {
            if subscriptionOperation == .idle {
                confirmedSubscriptionState = podcast.isSubscribed
            }
        }
        .task(id: podcast.stablePodcastIdentityKey) {
            let service = TranscriptSearchActor(modelContainer: modelContext.container)
            hasSearchableTranscripts = (try? await service
                .hasSearchableTranscripts(in: .podcast(podcast.stablePodcastIdentityKey))) == true
        }
        .onChange(of: searchText) { _, _ in
            filteredEpisodeDisplayLimit = Self.episodePageSize
            debounceEpisodeFilters()
        }
        .onChange(of: searchInTitle) { _, _ in
            filteredEpisodeDisplayLimit = Self.episodePageSize
            applyEpisodeFilters()
        }
        .onChange(of: searchInAuthor) { _, _ in
            filteredEpisodeDisplayLimit = Self.episodePageSize
            applyEpisodeFilters()
        }
        .onChange(of: searchInDescription) { _, _ in
            filteredEpisodeDisplayLimit = Self.episodePageSize
            applyEpisodeFilters()
        }
        .onChange(of: searchInTranscript) { _, _ in
            filteredEpisodeDisplayLimit = Self.episodePageSize
            debounceEpisodeFilters()
        }
        .onChange(of: hidePlayedAndArchived) { _, _ in
            filteredEpisodeDisplayLimit = Self.episodePageSize
            applyEpisodeFilters()
        }
        .onChange(of: sortOptionRawValue) { _, _ in
            filteredEpisodeDisplayLimit = Self.episodePageSize
            applyEpisodeFilters()
        }
        .onChange(of: podcast.metaData?.feedUpdateCheckDate) { _, _ in
            Task {
                await updatePredictedReleaseInfo()
            }
        }
        .onChange(of: podcast.isSubscribed) { _, newValue in
            guard subscriptionOperation == .idle else { return }
            confirmedSubscriptionState = newValue
        }
        .onDisappear {
            episodeFilterTask?.cancel()
        }
        .navigationDestination(isPresented: $showPodroll) {
            PodcastPodrollView(
                podcastTitle: podcast.title,
                items: podrollItems
            )
        }
        .sheet(isPresented: $showTranscriptSearch) {
            NavigationStack {
                TranscriptSearchView(
                    scope: .podcast(podcast.stablePodcastIdentityKey),
                    title: "Search \(podcast.title)",
                    emptyDescription: "Search every locally available transcript in this podcast."
                )
            }
        }
        .sheet(isPresented: $showFeedRepair) {
            FeedURLRepairSheet(
                podcastID: podcast.persistentModelID,
                currentURL: podcast.feed,
                modelContainer: modelContext.container
            ) {
                applyEpisodeFilters()
            }
        }
        .sheet(isPresented: $showAuthenticationEditor) {
            PodcastAccessEditorView(podcast: podcast) {
                Task { await refreshEpisodes() }
            }
        }
#if DEBUG
        .navigationDestination(isPresented: $showDebugMetadata) {
            PodcastDebugMetadataView(podcast: podcast)
        }
#endif
        .refreshable {
            await refreshEpisodes()
        }
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                Picker("Sort by", selection: Binding(
                    get: { sortOptionRawValue },
                    set: { sortOptionRawValue = $0 }
                )) {
                    ForEach(EpisodeSortOption.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .accessibilityHint("Sort the episodes in this podcast")

                Toggle(isOn: $hidePlayedAndArchived) {
                    Label("Hide played Episodes", systemImage: "eye.slash")
                }

                Menu {
                    if availableAlternativeFeeds.isEmpty == false {
                        Section("Alternative Feeds") {
                            ForEach(availableAlternativeFeeds) { alternativeFeed in
                                Button {
                                    Task {
                                        await switchToAlternativeFeed(alternativeFeed)
                                    }
                                } label: {
                                    Label(alternativeFeed.displayTitle, systemImage: "dot.radiowaves.left.and.right")
                                }
                                .disabled(isLoading || isSwitchingAlternativeFeed)
                            }
                        }
                    }

                    if displayedIsSubscribed {
                        Button(role: .destructive) {
                            Task { await toggleSubscriptionStatus() }
                        } label: {
                            Label("Unsubscribe", systemImage: "bell.slash")
                        }
                        .disabled(subscriptionOperation != .idle)
                    }

                    Button {
                        openSettings(.podcast(podcast))
                    } label: {
                        Label("Podcast Settings", systemImage: "gear")
                    }

                    Button {
                        showFeedRepair = true
                    } label: {
                        Label("Repair Feed URL", systemImage: "wrench.and.screwdriver")
                    }
                    .disabled(isLoading)

                    Button {
                        Task {
                            try? await PodcastModelActor(modelContainer: modelContext.container)
                                .archiveEpisodes(of: podcast.persistentModelID)
                        }
                    } label: {
                        Label("Archive all episodes", systemImage: "archivebox")
                    }

#if DEBUG
                    Button {
                        showDebugMetadata = true
                    } label: {
                        Label("Podcast debug metadata", systemImage: "ladybug")
                    }
#endif
                } label: {
                    Label("Manage podcast", systemImage: "ellipsis")
                }
                .accessibilityLabel("Manage podcast")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await refreshEpisodes()
                    }
                } label: {
                    if isLoading {
                        CircularProgressView(value: max(refreshProgress, 0.02), total: 1.0)
                    } else {
                        Label(
                            needsEpisodeImportRetry ? "Retry import" : "Refresh podcast",
                            systemImage: "arrow.clockwise"
                        )
                    }
                }
                .disabled(displayedIsSubscribed == false || isLoading)
                .accessibilityLabel(
                    isLoading
                        ? "Refreshing podcast"
                        : (needsEpisodeImportRetry ? "Retry episode import" : "Refresh podcast")
                )
                .accessibilityHint(
                    needsEpisodeImportRetry
                        ? "Retries importing episodes for this podcast"
                        : "Downloads the latest episodes from this podcast feed"
                )
                .accessibilityInputLabels([Text("Refresh podcast"), Text("Update podcast"), Text("Retry import")])
            }
        }
        .alert("Live notification", isPresented: isLiveNotificationPresented) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(liveNotificationMessage ?? "")
        }
    }

    private func updatePredictedReleaseInfo() async {
        let podcastID = podcast.persistentModelID
        let predictor = SubscriptionManager(modelContainer: modelContext.container)
        let releaseInfo = await predictor.predictedReleaseInfo(for: podcastID)
        predictedReleaseFrequencyLabel = releaseInfo?.cadenceLabel
#if DEBUG
        predictedReleaseDate = releaseInfo?.releaseDate ?? podcast.metaData?.nextPredictedReleaseDate
#endif
    }

    private func debounceEpisodeFilters() {
        Debounce.shared.perform(key: "PodcastDetailView.episodeFilters") {
            applyEpisodeFilters()
        }
    }

    private func loadMoreEpisodesIfNeeded(currentEpisode: Episode) {
        guard filteredEpisodeDisplayLimit < filteredEpisodeIDs.count else { return }
        guard visibleFilteredEpisodes.last?.persistentModelID == currentEpisode.persistentModelID else { return }
        let oldLimit = min(filteredEpisodeDisplayLimit, filteredEpisodeIDs.count)
        let newLimit = min(oldLimit + Self.episodePageSize, filteredEpisodeIDs.count)
        guard oldLimit < newLimit else { return }

        do {
            let page = try resolveVisiblePage(
                from: oldLimit..<newLimit,
                ids: filteredEpisodeIDs,
                urls: filteredEpisodeURLs
            )
            filteredEpisodes.append(contentsOf: page)
            filteredEpisodeDisplayLimit = newLimit
        } catch {
            errorMessage = "Failed to load more episodes: \(error.localizedDescription)"
        }
    }

    private func applyEpisodeFilters() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let listSort: PodcastEpisodeListSort = switch sortOption {
        case .newestFirst: .newestFirst
        case .oldestFirst: .oldestFirst
        case .titleAZ: .titleAZ
        case .titleZA: .titleZA
        }
        let request = PodcastEpisodeFilterRequest(
            query: query,
            searchInTitle: searchInTitle,
            searchInAuthor: searchInAuthor,
            searchInDescription: searchInDescription,
            searchInTranscript: searchInTranscript,
            hidePlayedAndArchived: hidePlayedAndArchived,
            sort: listSort
        )
        let podcastID = podcast.persistentModelID
        let actor = PodcastEpisodeFilterActor(modelContainer: modelContext.container)

        episodeFilterTask?.cancel()
        isFilteringEpisodes = true
        episodeFilterTask = Task {
            defer {
                if Task.isCancelled == false {
                    isFilteringEpisodes = false
                }
            }
            do {
                let result = try await actor.episodeIDs(
                    podcastID: podcastID,
                    request: request
                )
                guard Task.isCancelled == false else { return }
                let visibleEpisodes = try resolveVisiblePage(
                    from: 0..<min(result.episodeIDs.count, Self.episodePageSize),
                    ids: result.episodeIDs,
                    urls: result.episodeURLs
                )
                guard Task.isCancelled == false else { return }
                filteredEpisodeIDs = result.episodeIDs
                filteredEpisodeURLs = result.episodeURLs
                filteredEpisodes = visibleEpisodes
                filteredEpisodeDisplayLimit = Self.episodePageSize
            } catch {
                guard Task.isCancelled == false else { return }
                errorMessage = "Failed to load episodes: \(error.localizedDescription)"
            }
        }
    }

    private func resolveVisiblePage(
        from range: Range<Int>,
        ids: [PersistentIdentifier],
        urls: [URL?]
    ) throws -> [Episode] {
        guard range.isEmpty == false else { return [] }
        let pageIDs = Array(ids[range])
        let pageURLs = Array(urls[range])
        let signpostID = PodcastDetailFetchSignposts.begin("Podcast detail visible page fetch")
        let result = try modelContext.episodes(forPageIDs: pageIDs, urls: pageURLs)
        PodcastDetailFetchSignposts.end("Podcast detail visible page fetch", id: signpostID, count: result.count)
        return result
    }

    private func refreshEpisodes() async {
        guard displayedIsSubscribed else {
            return
        }

        isLoading = true
        refreshProgress = 0
        refreshProgressMessage = "Preparing refresh"
        errorMessage = nil
        if let feed = podcast.feed{
            do {
                let actor = PodcastModelActor(modelContainer: modelContext.container)
                
                let startedAt = Date()
                let summary = try await actor.updatePodcastWithSummary(feed, policy: .manualSingle) { update in
                    await MainActor.run {
                        refreshProgress = update.fractionCompleted
                        refreshProgressMessage = update.message
                    }
                }
#if DEBUG
                await RefreshHistoryStore.shared.record(
                    RefreshHistoryEntry(
                        startedAt: startedAt,
                        finishedAt: Date(),
                        trigger: .userInitiatedSingle,
                        checkedPodcasts: [
                            RefreshHistoryPodcastCheck(
                                title: podcast.title,
                                feedURL: feed,
                                result: summary.didUpdateFeed
                                    ? .refreshed(newEpisodeCount: summary.newEpisodeCount)
                                    : .feedNotUpdated
                            )
                        ]
                    )
                )
#endif
                podcast.message = nil
                await MainActor.run {
                    filteredEpisodeDisplayLimit = Self.episodePageSize
                    applyEpisodeFilters()
                }
                
            } catch {
#if DEBUG
                await RefreshHistoryStore.shared.record(
                    RefreshHistoryEntry(
                        startedAt: Date(),
                        finishedAt: Date(),
                        trigger: .userInitiatedSingle,
                        checkedPodcasts: [
                            RefreshHistoryPodcastCheck(
                                title: podcast.title,
                                feedURL: feed,
                                result: .failed(error.localizedDescription)
                            )
                        ]
                    )
                )
#endif
                await MainActor.run {
                    errorMessage = Self.userFacingRefreshError(error)
                }
            }
            
            await MainActor.run {
                isLoading = false
                refreshProgress = 0
                refreshProgressMessage = nil
            }
        }
    }

    private static func userFacingRefreshError(_ error: Error) -> String {
        if case PodcastFeedResolverError.authenticationRequired = error {
            return String(localized: "This podcast requires authentication. Choose Fix Authentication to update access.")
        }
        if case PodcastFeedResolverError.bearerAuthenticationRequired = error {
            return String(localized: "This podcast requires an updated access token. Choose Fix Authentication to update access.")
        }
        if case PodcastParserError.couldNotLoad(_, let statusCode, _) = error,
           statusCode == 401 {
            return String(localized: "The saved credentials were rejected. Choose Fix Authentication to sign in again.")
        }
        if case PodcastFeedResolverError.httpStatus(_, let statusCode, _) = error,
           statusCode == 401 {
            return String(localized: "The saved credentials were rejected. Choose Fix Authentication to sign in again.")
        }
        if error is URLError {
            return String(localized: "The podcast server is temporarily unavailable. Try again later.")
        }
        return String(localized: "The podcast could not be refreshed. Check your connection and try again.")
    }

    private var needsEpisodeImportRetry: Bool {
        podcast.metaData?.lastFeedFailureMessage?.localizedCaseInsensitiveContains("import") == true
    }

    private func refreshEpisodesIfNeeded() async {
        guard hasAttemptedInitialFeedImport == false else { return }
        guard needsInitialFeedImport else { return }

        hasAttemptedInitialFeedImport = true
        await refreshEpisodes()
    }

    private func toggleSubscriptionStatus() async {
        guard subscriptionOperation == .idle else { return }
        let requestedState = !displayedIsSubscribed
        await MainActor.run {
            subscriptionErrorMessage = nil
            subscriptionOperation = .committing(requestedState)
        }
        let actor = PodcastModelActor(modelContainer: modelContext.container)
        do {
            let result = try await actor.setSubscriptionStatus(
                podcast.persistentModelID,
                isSubscribed: requestedState
            )
            await MainActor.run {
                confirmedSubscriptionState = result.isSubscribed
                subscriptionOperation = .idle
                AccessibilityNotification.Announcement(
                    result.isSubscribed ? "Subscribed" : "Unsubscribed"
                ).post()
            }
        } catch {
            await MainActor.run {
                subscriptionErrorMessage = "Could not update subscription: \(error.localizedDescription)"
                subscriptionOperation = .idle
                AccessibilityNotification.Announcement(
                    "Could not update subscription. Try again."
                ).post()
            }
        }
    }

    private func switchToAlternativeFeed(_ alternativeFeed: PodcastAlternativeFeed) async {
        guard isSwitchingAlternativeFeed == false else { return }

            await MainActor.run {
                isSwitchingAlternativeFeed = true
                isLoading = true
                refreshProgress = 0
                refreshProgressMessage = "Switching feed"
                errorMessage = nil
            }

        do {
            let actor = PodcastModelActor(modelContainer: modelContext.container)
            try await actor.switchPodcastFeed(podcast.persistentModelID, to: alternativeFeed) { update in
                await MainActor.run {
                    refreshProgress = update.fractionCompleted
                    refreshProgressMessage = update.message
                }
            }
            await MainActor.run {
                podcast.message = nil
                applyEpisodeFilters()
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to switch feed: \(error.localizedDescription)"
            }
        }

        await MainActor.run {
            isSwitchingAlternativeFeed = false
            isLoading = false
            refreshProgress = 0
            refreshProgressMessage = nil
        }
    }

    private func scheduleLiveNotification(for liveItem: PodcastLiveItem) async {
        guard showLivePodcasts else { return }
        guard let start = liveItem.start else { return }

        do {
            guard await PodcastSettingsModelActor(modelContainer: modelContext.container)
                .getLiveItemNotificationsEnabled(for: podcast.feed) else {
                throw NotificationSchedulingError.liveNotificationsDisabled
            }

            let notificationManager = NotificationManager()
            try await notificationManager.scheduleNotification(
                identifier: await notificationManager.liveNotificationIdentifier(
                    podcastFeed: podcast.feed,
                    podcastTitle: podcast.title,
                    liveItemID: liveItem.id
                ),
                title: podcast.title,
                body: "\(liveItem.title) starts now.",
                date: start,
                userInfo: [
                    "podcastFeed": podcast.feed?.absoluteString ?? "",
                    "liveItem": liveItem.id,
                    "liveStart": start.timeIntervalSince1970
                ]
            )
            await MainActor.run {
                liveNotificationMessage = "Notification scheduled for \(start.formatted(date: .abbreviated, time: .shortened))."
            }
        } catch {
            await MainActor.run {
                liveNotificationMessage = error.localizedDescription
            }
        }
    }

    private var showLivePodcasts: Bool {
        defaultSettings.first?.showLivePodcasts != false
    }

}

private struct PodcastAbandonedFeedCard: View {
    let metadata: PodcastMetaData?

    var body: some View {
        if let metadata,
           let assessment = metadata.feedAbandonmentAssessment {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    assessment.title,
                    systemImage: assessment.kind == .unavailableFeed
                        ? "exclamationmark.triangle.fill"
                        : "calendar.badge.exclamationmark"
                )
                    .font(.subheadline.weight(.semibold))

                Text(assessment.detail)
                    .font(.caption)
                    .esaForeground(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.3))
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct FeedURLRepairSheet: View {
    let podcastID: PersistentIdentifier
    let currentURL: URL?
    let modelContainer: ModelContainer
    let didSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var candidate = ""
    @State private var preview: PodcastFeedReplacementPreview?
    @State private var isValidating = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showIdentityWarning = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Current feed") {
                    Text(currentURL?.redactedPodcastURLString ?? "No feed URL")
                        .font(.footnote)
                        .textSelection(.enabled)
                }

                Section("Replacement feed") {
#if os(iOS)
                    TextField("https://example.com/feed.xml", text: $candidate, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onChange(of: candidate) { _, _ in
                            preview = nil
                            errorMessage = nil
                        }
#else
                    TextField("https://example.com/feed.xml", text: $candidate, axis: .vertical)
                        .autocorrectionDisabled()
                        .onChange(of: candidate) { _, _ in
                            preview = nil
                            errorMessage = nil
                        }
#endif

                    Button {
                        Task { await validate() }
                    } label: {
                        if isValidating {
                            ProgressView()
                        } else {
                            Label("Validate Feed", systemImage: "checkmark.shield")
                        }
                    }
                    .disabled(candidateURL == nil || isValidating || isSaving)
                }

                if let preview {
                    Section("Validated feed") {
                        LabeledContent("Title", value: preview.title)
                        LabeledContent("Episodes", value: "\(preview.episodeCount)")
                        LabeledContent("Resolved URL") {
                            Text(preview.resolvedURL.redactedPodcastURLString)
                                .font(.footnote)
                                .textSelection(.enabled)
                        }
                        if preview.matchesExistingEpisodes == false {
                            Label(
                                "No existing episode identifiers matched. Saving will require confirmation.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Repair Feed URL")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let preview else { return }
                        if preview.matchesExistingEpisodes {
                            Task { await save(allowUnverifiedIdentity: false) }
                        } else {
                            showIdentityWarning = true
                        }
                    }
                    .disabled(preview == nil || isSaving || isValidating)
                }
            }
            .confirmationDialog(
                "This feed could not be matched to existing episodes.",
                isPresented: $showIdentityWarning,
                titleVisibility: .visible
            ) {
                Button("Save Replacement Feed", role: .destructive) {
                    Task { await save(allowUnverifiedIdentity: true) }
                }
            } message: {
                Text("Your existing episodes and playback data will be retained. Only save if this is the same podcast.")
            }
        }
    }

    private var candidateURL: URL? {
        URL(string: candidate.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @MainActor
    private func validate() async {
        guard let candidateURL else { return }
        isValidating = true
        preview = nil
        errorMessage = nil
        do {
            preview = try await PodcastModelActor(modelContainer: modelContainer)
                .previewFeedReplacement(podcastID, candidateURL: candidateURL)
        } catch {
            errorMessage = error.localizedDescription
        }
        isValidating = false
    }

    @MainActor
    private func save(allowUnverifiedIdentity: Bool) async {
        guard let candidateURL else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await PodcastModelActor(modelContainer: modelContainer).replacePodcastFeed(
                podcastID,
                candidateURL: candidateURL,
                allowUnverifiedIdentity: allowUnverifiedIdentity,
                reason: .explicitSwitch
            )
            didSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

// Heavy metadata block (socials, people, namespace tags, HTML description).
// Extracted so it forms an observation boundary and shrinks the very large
// PodcastDetailView body type, making re-renders far cheaper.
private struct PodcastDetailMetadataSections: View {
    let podcast: Podcast
    let showsLiveMetadata: Bool

    var body: some View {
        SocialView(socials: podcast.social)
            .padding()
        PeopleView(people: podcast.people)
            .padding()
        PodcastNamespaceMetadataView(
            optionalTags: podcast.optionalTags,
            title: "Podcast Metadata",
            hidesRenderableValueBlocks: true,
            showsLiveMetadata: showsLiveMetadata
        )
            .padding()
        if let desc = podcast.desc {
            ShownoteContentView(html: desc)
                .padding()
        }
    }
}

private struct PodcastLiveItemControlsView: View {
    @Environment(\.openURL) private var openURL

    let currentLiveItem: PodcastLiveItem?
    let nextLiveItem: PodcastLiveItem?
    let liveItemNotificationsEnabled: Bool
    let podcastTitle: String
    let artworkURL: URL?
    let scheduleNotification: (PodcastLiveItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let currentLiveItem {
                Menu {
                    liveMenuItems(for: currentLiveItem)
                } label: {
                    Label("Live Now: \(currentLiveItem.title)", systemImage: "dot.radiowaves.left.and.right")
                        .lineLimit(2)
                }
                .buttonStyle(.glass(.clear))
            }

            if liveItemNotificationsEnabled, let nextLiveItem, let start = nextLiveItem.start {
                Button {
                    scheduleNotification(nextLiveItem)
                } label: {
                    Label(
                        "Notify Me: \(start.formatted(date: .abbreviated, time: .shortened))",
                        systemImage: "bell.badge"
                    )
                }
                .buttonStyle(.glass(.clear))
            }
        }
    }

    @ViewBuilder
    private func liveMenuItems(for liveItem: PodcastLiveItem) -> some View {
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

        if liveItem.preferredStream != nil {
            Button {
                Task {
                    await Player.shared.playLiveItem(
                        liveItem,
                        podcastTitle: podcastTitle,
                        artworkURL: artworkURL,
                        link: liveItem.link
                    )
                }
            } label: {
                Label("Play Live Stream", systemImage: "play.circle")
            }
        }
    }
}

#Preview("Podcast Detail") {
    let previewFilesManager = DownloadedFilesManager(folder: FileManager.default.temporaryDirectory)
    let previewContainer = try! ModelContainer(for: Podcast.self, Episode.self)

    NavigationStack {
        PodcastDetailView(podcast: PodcastDetailPreviewData.samplePodcast)
    }
    .environment(previewFilesManager)
    .modelContainer(previewContainer)
}

private enum PodcastDetailPreviewData {
    static var samplePodcast: Podcast {
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        podcast.title = "Preview Engineering Weekly"
        podcast.author = "Preview Team"
        podcast.desc = """
        <p>A sample podcast description for the PodcastDetailView preview.</p>
        <p><a href=\"https://example.com\">Visit website</a></p>
        """
        podcast.link = URL(string: "https://example.com/show")
        podcast.imageURL = URL(string: "https://picsum.photos/400")
        podcast.copyright = "© 2026 Preview Network"
        podcast.lastBuildDate = Date(timeIntervalSinceNow: -(60 * 60 * 2))
        podcast.metaData?.feedUpdateCheckDate = Date(timeIntervalSinceNow: -(60 * 30))

        podcast.funding = [
            FundingInfo(url: URL(string: "https://example.com/support")!, label: "Support"),
            FundingInfo(url: URL(string: "https://example.com/membership")!, label: "Membership")
        ]
        podcast.social = [
            SocialInfo(url: URL(string: "https://example.social/@preview")!, socialprotocol: "activitypub", accountId: "@preview", accountURL: URL(string: "https://example.social/@preview"), priority: 1),
            SocialInfo(url: URL(string: "https://example.com/team")!, socialprotocol: "website", accountId: nil, accountURL: nil, priority: 2)
        ]
        podcast.people = [
            PersonInfo(name: "Alex Preview", role: "host", href: URL(string: "https://example.com/alex"), img: nil),
            PersonInfo(name: "Sam Builder", role: "producer", href: URL(string: "https://example.com/sam"), img: URL(string: "https://picsum.photos/80"))
        ]

        var tags = PodcastNamespaceOptionalTags()
        tags.episode = [NamespaceNode(name: "podcast:episode", attributes: ["number": "42"])]
        tags.season = [NamespaceNode(name: "podcast:season", value: "4", attributes: ["name": "Scaling SwiftUI"])]
        tags.chat = [NamespaceNode(name: "podcast:chat", attributes: ["url": "https://chat.example.com", "protocol": "irc"])]
        tags.license = [NamespaceNode(name: "podcast:license", value: "CC-BY-4.0")]
        tags.value = [
            NamespaceNode(
                name: "podcast:value",
                attributes: ["type": "lightning", "method": "keysend", "suggested": "0.00000005000"],
                children: [
                    NamespaceNode(
                        name: "podcast:valueRecipient",
                        attributes: ["name": "Host", "address": "03abc", "split": "80"]
                    ),
                    NamespaceNode(
                        name: "podcast:valueRecipient",
                        attributes: ["name": "Producer", "address": "03def", "split": "20"]
                    )
                ]
            )
        ]
        podcast.optionalTags = tags

        let latest = Episode(
            title: "Making SwiftUI Metadata Views Better",
            publishDate: Date(timeIntervalSinceNow: -(60 * 60 * 20)),
            url: URL(string: "https://example.com/episodes/42.mp3")!,
            podcast: podcast,
            duration: 3200,
            author: "Alex Preview"
        )
        latest.desc = "Refactoring metadata views and improving previews."
        latest.link = URL(string: "https://example.com/episodes/42")
        latest.externalFiles = [
            ExternalFile(
                url: "https://example.com/transcripts/42.vtt",
                category: .transcript,
                source: "podcastindex",
                fileType: "text/vtt"
            )
        ]
        latest.metaData?.playPosition = 980
        latest.metaData?.maxPlayposition = 1600

        let chapterOne = Marker(start: 0, title: "Intro", type: .mp3, duration: 120)
        let chapterTwo = Marker(start: 120, title: "UI Grouping", type: .mp3, duration: 900)
        latest.chapters = [chapterOne, chapterTwo]
        latest.chapters?.forEach { $0.episode = latest }

        let previous = Episode(
            title: "Designing Better Episode Detail Screens",
            publishDate: Date(timeIntervalSinceNow: -(60 * 60 * 48)),
            url: URL(string: "https://example.com/episodes/41.mp3")!,
            podcast: podcast,
            duration: 2800,
            author: "Sam Builder"
        )
        previous.desc = "Layout and navigation improvements."
        previous.link = URL(string: "https://example.com/episodes/41")
        previous.metaData?.maxPlayposition = previous.duration
        previous.metaData?.completionDate = Date(timeIntervalSinceNow: -(60 * 60 * 8))

        podcast.episodes = [latest, previous]
        return podcast
    }
}
