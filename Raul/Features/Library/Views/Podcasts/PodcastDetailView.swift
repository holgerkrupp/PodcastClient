//
//  EpisodeView.swift
//  Raul
//
//  Created by Holger Krupp on 05.05.25.
//

import SwiftUI
import SwiftData
import RichText

struct PodcastDetailView: View {
    
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

        var comparator: (Episode, Episode) -> Bool {
            switch self {
            case .newestFirst:
                return { ($0.publishDate ?? .distantPast) > ($1.publishDate ?? .distantPast) }
            case .oldestFirst:
                return { ($0.publishDate ?? .distantFuture) < ($1.publishDate ?? .distantFuture) }
            case .titleAZ:
                return { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            case .titleZA:
                return { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
            }
        }
    }

    
    @Bindable var podcast: Podcast
    @State private var backgroundUIImage: UIImage?
    @State private var isLoading = false
    @State private var isSwitchingAlternativeFeed = false
    @State private var refreshProgress: Double = 0
    @State private var refreshProgressMessage: String?
    @State private var errorMessage: String?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.deviceUIStyle) var style
    @Environment(\.openPodcastSettings) private var openSettings
    @Query(filter: PodcastSettingsView.defaultSettingsFilter) private var defaultSettings: [PodcastSettings]

    @State private var showPodroll: Bool = false
    @State private var showDebugMetadata: Bool = false
    @State private var liveNotificationMessage: String?
    @State private var hasAttemptedInitialFeedImport = false
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
    @State private var displayedEpisodeLimit = Self.episodePageSize
    @AppStorage("HidePlayedAndArchived") private var hidePlayedAndArchived: Bool = false

    private static let episodePageSize = 40

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
        podcast.optionalTags?.liveItem?.compactMap(PodcastLiveItem.init(node:)) ?? []
    }

    private var displayedEpisodes: ArraySlice<Episode> {
        filteredEpisodes.prefix(displayedEpisodeLimit)
    }

    private var hasMoreFilteredEpisodes: Bool {
        displayedEpisodeLimit < filteredEpisodes.count
    }

    private var needsInitialFeedImport: Bool {
        podcast.isSubscribed
            && podcast.feed != nil
            && podcast.metaData?.lastRefresh == nil
            && (podcast.episodes?.isEmpty ?? true)
    }

    private var isFeedAbandoned: Bool {
        podcast.metaData?.isFeedLikelyAbandoned == true
    }

    @ViewBuilder
    private var abandonedFeedCard: some View {
        if isFeedAbandoned, let metadata = podcast.metaData {
            VStack(alignment: .leading, spacing: 10) {
                Label("Podcast feed abandoned", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)

                Text("The feed has been unreachable repeatedly for more than seven days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Last visible") {
                    Text(metadata.lastRefresh?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                }

                LabeledContent("Server response") {
                    Text(metadata.feedFailureStatusDescription ?? "Unknown")
                }

                LabeledContent("First failed check") {
                    Text(metadata.firstConsecutiveFeedFailureDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown")
                }

                LabeledContent("Latest failed check") {
                    Text(metadata.lastFeedFailureDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown")
                }

                LabeledContent("Consecutive failures") {
                    Text("\(metadata.consecutiveFeedFailureCount)")
                        .monospacedDigit()
                }

                if let error = metadata.lastFeedFailureMessage, error.isEmpty == false {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .font(.caption)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.3))
            }
            .padding(.top, 6)
        }
    }

    private var currentLiveItem: PodcastLiveItem? {
        liveItems.first { $0.status == .live }
    }

    private var nextLiveItem: PodcastLiveItem? {
        liveItems
            .filter { liveItem in
                liveItem.status != .ended && (liveItem.start ?? .distantPast) > Date()
            }
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
                Text("\(Int(refreshProgress * 100))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
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
   
        
      

            
            AnyView(List {
                
                
                
                Section{
                    VStack(alignment: .leading) {
                        
                        HStack{
                            if let lastBuildDate = podcast.lastBuildDate {
                                Text("Last updated: \(lastBuildDate.formatted(date: .numeric, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if let metaData = podcast.metaData, let lastRefreshDate = metaData.feedUpdateCheckDate {
                                Text("Last refresh: \(lastRefreshDate.formatted(date: .numeric, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }

                        abandonedFeedCard

                        if isLoading {
                            refreshProgressCard
                                .padding(.top, 6)
                        }
                        
                        HStack {
                            
                            CoverImageView(podcast: podcast)
                                .frame(width: 50, height: 50)
                                .cornerRadius(8)
                            
                            VStack{
                                if let author = podcast.author {
                                    Text(author)
                                        .font(.caption)
                                }
                                Text(podcast.title)
                                    .font(.headline)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 8)

                            if let podcastLink = podcast.link {
                                Link(destination: podcastLink) {
                                    Image(systemName: "link")
                                        .imageScale(.medium)
                                }
                                .buttonStyle(.glass(.clear))
                                .accessibilityLabel("Open podcast website")
                            }
#if DEBUG
                            Button {
                                showDebugMetadata = true
                            } label: {
                                Image(systemName: "ladybug")
                                    .imageScale(.small)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Podcast debug metadata")
#endif
                        }

                        let metadataChips = PodcastDetailMetadataChipsView(podcast: podcast)
                        if metadataChips.hasContent {
                            metadataChips
                                .padding(.top, 4)
                        }

                        if currentLiveItem != nil || (nextLiveItem != nil && liveItemNotificationsEnabled) {
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
                            .padding(.top, 4)
                        }

                        PodcastTrailerButton(
                            trailers: podcastTrailers,
                            podcastTitle: podcast.title,
                            artworkURL: podcast.imageURL
                        )

                        if podrollItems.isEmpty == false {
                            Button {
                                showPodroll = true
                            } label: {
                                Label("Podroll", systemImage: "rectangle.connected.to.line.below")
                            }
                            .buttonStyle(.glass(.clear))
                            .accessibilityLabel("Open podroll")
                            .accessibilityHint("Shows podcasts recommended by this podcast")
                        }

                        if podcast.funding.count > 0 {
                            HStack{
                                ForEach(podcast.funding ) { fund in
                                    Link(destination: fund.url) {
                                        Label(fund.label, systemImage: style.currencySFSymbolName)
                                    }
                                    .buttonStyle(.glass(.clear))
                                    
                                    if fund != podcast.funding.last {
                                        Spacer()
                                    }
                                }
                            }
                        }

                        PodcastValueSplitView(optionalTags: podcast.optionalTags, funding: podcast.funding)
                        /*
                    
                            NavigationLink(destination: BookmarkListView(podcast: podcast)) {
                                Label("Show Bookmarks", systemImage: "bookmark.fill")
                                   
                            }
                            .buttonStyle(.glass(.clear))
                            .padding()
                        */
                        
                        if let copyright = podcast.copyright {
                            Text(copyright)
                                .font(.caption)
                        }
                        SocialView(socials: podcast.social)
                            .padding()
                        PeopleView(people: podcast.people)
                            .padding()
                        PodcastNamespaceMetadataView(
                            optionalTags: podcast.optionalTags,
                            title: "Podcast Metadata",
                            hidesRenderableValueBlocks: true
                        )
                            .padding()
                        if let desc = podcast.desc {
#if os(iOS)
                            RichText(html: desc)
                                .linkColor(light: Color.secondary, dark: Color.secondary)
                                .backgroundColor(.transparent)
                                .padding()
#else
                            RichText(html: desc)
                                .backgroundColor(.transparent)
                                .padding()
#endif
                            
                            
                        }

                        Button(podcast.isSubscribed ? "Unsubscribe" : "Subscribe") {
                            Task {
                                await toggleSubscriptionStatus()
                            }
                        }
                        .buttonStyle(.glass(.clear))

                        if availableAlternativeFeeds.isEmpty == false {
                            Menu {
                                ForEach(availableAlternativeFeeds) { alternativeFeed in
                                    Button {
                                        Task {
                                            await switchToAlternativeFeed(alternativeFeed)
                                        }
                                    } label: {
                                        Label(alternativeFeed.displayTitle, systemImage: "dot.radiowaves.left.and.right")
                                    }
                                }
                            } label: {
                                if isSwitchingAlternativeFeed {
                                    ProgressView()
                                } else {
                                    Label("Switch Alternative Feed", systemImage: "arrow.triangle.branch")
                                }
                            }
                            .buttonStyle(.glass(.clear))
                            .disabled(isLoading || isSwitchingAlternativeFeed)
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if podcast.isSubscribed == false {
                            Text("This podcast stays in the database, but it is skipped by bulk refresh.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowSeparator(.hidden)
                .background(.clear)
                .listRowBackground(Color.clear)

                .overlay {
                    if  let message = podcast.message {
                        
                        ZStack {
                            RoundedRectangle(cornerRadius:  8.0)
                                .fill(Color.clear)
                                .ignoresSafeArea()
                            HStack(alignment: .center) {
                                
                                ProgressView()
                                    .frame(width: 100, height: 50)
                                Text(message)
                                    .foregroundStyle(Color.primary)
                                    .font(.title.bold())
                                    
                            }
                        }
                        .background{
                            RoundedRectangle(cornerRadius:  8.0)
                                .fill(.background.opacity(0.3))
                        }
                     
                        
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 20.0))
                        .frame(maxWidth: 300, maxHeight: 150, alignment: .center)
                    
                  
                        
                     
                    }
                
                }
                
                Section{
                    ForEach(displayedEpisodes, id: \.id) { episode in
                        ZStack{
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
                        .listRowInsets(.init(top: 0,
                                             leading: 0,
                                             bottom: 0,
                                             trailing: 0))
                        .ignoresSafeArea()
                        .onAppear {
                            loadMoreEpisodesIfNeeded(currentEpisode: episode)
                        }
                        
                        
                    }
                    .onDelete { indexSet in
                        Task {
                            for index in indexSet {
                                 let episodeID = filteredEpisodes[index].persistentModelID
                                    try? await PodcastModelActor(modelContainer: modelContext.container).deleteEpisode(episodeID)
                                
                            }
                        }
                    }
                    if hasMoreFilteredEpisodes {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .onAppear {
                                loadMoreEpisodes()
                            }
                    }
                }
                .listRowSeparator(.hidden)
            })
            .background{
                if let backgroundUIImage {
                    Image(uiImage: backgroundUIImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity) // Ensure it takes up all available space
                                        .ignoresSafeArea(.all) // Crucial: extends the image behind safe areas (like under the status bar)
                                        
                        .blur(radius: 20)
                        .opacity(0.5)

                    
                } else {
                    Color.accent.ignoresSafeArea()
                }
            }

            .listStyle(PlainListStyle())
            .padding(.top, 0)
            .searchable(text: $searchText)
            .task {
                applyEpisodeFilters()
                await refreshEpisodesIfNeeded()
            }
            .task(id: podcast.imageURL) {
                await loadBackgroundImage()
            }
            .onChange(of: searchText) { _, _ in
                debounceEpisodeFilters()
            }
            .onChange(of: searchInTitle) { _, _ in
                applyEpisodeFilters(resetDisplayLimit: true)
            }
            .onChange(of: searchInAuthor) { _, _ in
                applyEpisodeFilters(resetDisplayLimit: true)
            }
            .onChange(of: searchInDescription) { _, _ in
                applyEpisodeFilters(resetDisplayLimit: true)
            }
            .onChange(of: searchInTranscript) { _, _ in
                debounceEpisodeFilters()
            }
            .onChange(of: hidePlayedAndArchived) { _, _ in
                applyEpisodeFilters(resetDisplayLimit: true)
            }
            .onChange(of: sortOptionRawValue) { _, _ in
                applyEpisodeFilters(resetDisplayLimit: true)
            }
            .onChange(of: podcast.episodes?.count ?? 0) { _, _ in
                applyEpisodeFilters(resetDisplayLimit: true)
            }
            .navigationTitle(podcast.title)
            .navigationDestination(isPresented: $showPodroll) {
                PodcastPodrollView(
                    podcastTitle: podcast.title,
                    items: podrollItems
                )
            }
#if DEBUG
            .navigationDestination(isPresented: $showDebugMetadata) {
                PodcastDebugMetadataView(podcast: podcast)
            }
#endif
            .refreshable {
                Task{
                    await refreshEpisodes()
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort by", selection: Binding(
                            get: { sortOptionRawValue },
                            set: { sortOptionRawValue = $0 }
                        )) {
                            ForEach(EpisodeSortOption.allCases) { option in
                                Text(option.label).tag(option.rawValue)
                            }
                        }
                        Divider()
                        Toggle(isOn: $hidePlayedAndArchived) {
                            Label("Hide played Episodes", systemImage: "eye.slash")
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Episode sort and visibility")
                    .accessibilityHint("Choose episode sort order and hide played episodes")
                    .accessibilityInputLabels([Text("Sort episodes"), Text("Episode sort")])
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        openSettings(.podcast(podcast))
                    }) {
                        Image(systemName: "gear")
                    }
                    .accessibilityLabel("Podcast settings")
                    .accessibilityHint("Open settings for this podcast")
                    .accessibilityInputLabels([Text("Podcast settings"), Text("Open settings")])
                    
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        Task {
                            await refreshEpisodes()
                        }
                    }) {
                        if isLoading {
                            CircularProgressView(
                                value: max(refreshProgress, 0.02),
                                total: 1.0
                            )
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(podcast.isSubscribed == false || isLoading)
                    .accessibilityLabel(isLoading ? "Refreshing podcast" : "Refresh podcast")
                    .accessibilityHint("Downloads the latest episodes from this podcast feed")
                    .accessibilityInputLabels([Text("Refresh podcast"), Text("Update podcast")])
                    
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        Task {
                            try? await  PodcastModelActor(modelContainer: modelContext.container).archiveEpisodes(of: podcast.persistentModelID)
                        }
                    }) {
                        Image(systemName: "archivebox")
                    }
                    .accessibilityLabel("Archive all episodes")
                    .accessibilityHint("Marks all episodes in this podcast as archived")
                    .accessibilityInputLabels([Text("Archive all episodes"), Text("Archive podcast episodes")])
                }
                
                
            }
        .alert("Live notification", isPresented: isLiveNotificationPresented) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(liveNotificationMessage ?? "")
        }
        

    }

    private func debounceEpisodeFilters() {
        Debounce.shared.perform {
            applyEpisodeFilters(resetDisplayLimit: true)
        }
    }

    private func loadBackgroundImage() async {
        guard let imageURL = podcast.imageURL else {
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

    private func applyEpisodeFilters(resetDisplayLimit: Bool = false) {
        let episodes = podcast.episodes ?? []
        if resetDisplayLimit {
            displayedEpisodeLimit = Self.episodePageSize
        }

        let visibleEpisodes: [Episode]
        if hidePlayedAndArchived {
            visibleEpisodes = episodes.filter { $0.maxPlayProgress < 0.95 }
        } else {
            visibleEpisodes = episodes
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else {
            filteredEpisodes = visibleEpisodes.sorted(by: sortOption.comparator)
            return
        }

        filteredEpisodes = visibleEpisodes
            .filter { episode in
                if searchInTitle, episode.title.localizedStandardContains(query) {
                    return true
                }
                if searchInAuthor, let author = episode.author, author.localizedStandardContains(query) {
                    return true
                }
                if searchInDescription, let desc = episode.desc, desc.localizedStandardContains(query) {
                    return true
                }
                if searchInTranscript,
                   let lines = episode.transcriptLines,
                   lines.contains(where: { $0.text.localizedStandardContains(query) }) {
                    return true
                }

                return false
            }
            .sorted(by: sortOption.comparator)
    }

    private func loadMoreEpisodesIfNeeded(currentEpisode: Episode) {
        guard hasMoreFilteredEpisodes else { return }
        guard displayedEpisodes.last?.persistentModelID == currentEpisode.persistentModelID else { return }
        loadMoreEpisodes()
    }

    private func loadMoreEpisodes() {
        displayedEpisodeLimit = min(
            displayedEpisodeLimit + Self.episodePageSize,
            filteredEpisodes.count
        )
    }
    
    private func refreshEpisodes() async {
        guard podcast.isSubscribed else {
            return
        }

        isLoading = true
        refreshProgress = 0
        refreshProgressMessage = "Preparing refresh"
        errorMessage = nil
        if let feed = podcast.feed{
            do {
                let actor = PodcastModelActor(modelContainer: modelContext.container)
                
                _ =  try await actor.updatePodcast(feed, force: true) { update in
                    await MainActor.run {
                        refreshProgress = update.fractionCompleted
                        refreshProgressMessage = update.message
                    }
                }
                podcast.message = nil
                
            } catch {
                await MainActor.run {
                    let nsError = error as NSError
                    errorMessage = "Failed to refresh episodes: \(error.localizedDescription) (\(nsError.domain) \(nsError.code))"
                }
            }
            
            await MainActor.run {
                isLoading = false
                refreshProgress = 0
                refreshProgressMessage = nil
            }
        }
    }

    private func refreshEpisodesIfNeeded() async {
        guard hasAttemptedInitialFeedImport == false else { return }
        guard needsInitialFeedImport else { return }

        hasAttemptedInitialFeedImport = true
        await refreshEpisodes()
    }

    private func toggleSubscriptionStatus() async {
        let actor = PodcastModelActor(modelContainer: modelContext.container)
        await actor.setSubscriptionStatus(podcast.persistentModelID, isSubscribed: !podcast.isSubscribed)
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
                    "liveItem": liveItem.id
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

        ForEach(liveItem.contentLinks) { contentLink in
            Button {
                openURL(contentLink.url)
            } label: {
                Label(contentLink.label, systemImage: "link")
            }
        }

        if let streamURL = liveItem.streamURL {
            Button {
                Task {
                    await Player.shared.playLiveStream(
                        url: streamURL,
                        title: liveItem.title,
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

private struct PodcastLiveItem: Identifiable {
    enum Status: String {
        case pending
        case live
        case ended
    }

    let id: String
    let title: String
    let status: Status
    let start: Date?
    let end: Date?
    let link: URL?
    let contentLinks: [PodcastLiveContentLink]
    let streamURL: URL?

    init?(node: NamespaceNode) {
        let guid = node.firstChild(localName: "guid")?.trimmedValue
        let link = node.firstChild(localName: "link")?.trimmedValue.flatMap(URL.init(string:))
        let streamURL = node.liveStreamURL
        let title = node.firstChild(localName: "title")?.trimmedValue ?? "Live Event"
        let start = node.attributes["start"].flatMap(Self.parseDate(_:))
        let end = node.attributes["end"].flatMap(Self.parseDate(_:))
        let status = Status(rawValue: node.attributes["status"] ?? "") ?? .pending

        self.id = guid ?? streamURL?.absoluteString ?? link?.absoluteString ?? "\(title)-\(node.attributes["start"] ?? "")"
        self.title = title
        self.status = status
        self.start = start
        self.end = end
        self.link = link
        self.contentLinks = node.children(localName: "contentLink").compactMap(PodcastLiveContentLink.init(node:))
        self.streamURL = streamURL
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) {
            return date
        }

        let compactTimeZoneFormatter = DateFormatter()
        compactTimeZoneFormatter.locale = Locale(identifier: "en_US_POSIX")
        compactTimeZoneFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        if let date = compactTimeZoneFormatter.date(from: value) {
            return date
        }

        compactTimeZoneFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return compactTimeZoneFormatter.date(from: value)
    }
}

private struct PodcastLiveContentLink: Identifiable {
    let id: URL
    let label: String
    let url: URL

    init?(node: NamespaceNode) {
        guard let href = node.attributes["href"], let url = URL(string: href) else {
            return nil
        }

        self.id = url
        self.label = node.trimmedValue ?? url.host() ?? "Open Link"
        self.url = url
    }
}

private extension NamespaceNode {
    var localName: String {
        if let separator = name.lastIndex(of: ":") {
            return String(name[name.index(after: separator)...])
        }
        return name
    }

    var trimmedValue: String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    func firstChild(localName: String) -> NamespaceNode? {
        children.first { $0.localName == localName }
    }

    func children(localName: String) -> [NamespaceNode] {
        children.filter { $0.localName == localName }
    }

    var liveStreamURL: URL? {
        for alternateEnclosure in children(localName: "alternateEnclosure") {
            let sources = alternateEnclosure.children(localName: "source")
            if let defaultSource = sources.first(where: { $0.attributes["uri"] != nil })?.attributes["uri"],
               let url = URL(string: defaultSource) {
                return url
            }
        }

        if let enclosureURL = firstChild(localName: "enclosure")?.attributes["url"],
           let url = URL(string: enclosureURL) {
            return url
        }

        return nil
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
