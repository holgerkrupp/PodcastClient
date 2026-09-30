import SwiftUI
import SwiftData

extension Notification.Name {
    static let inboxDidChange = Notification.Name("inboxDidChange")
}

enum InboxSection: String, CaseIterable, Identifiable {
    case inbox
    case iCloudDrive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox:
            return "Inbox"
        case .iCloudDrive:
            return "Sideloading"
        }
    }
}

struct InboxView: View {
    @State private var selectedSection: InboxSection = .inbox

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inbox section", selection: $selectedSection) {
                ForEach(InboxSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            Group {
                switch selectedSection {
                case .inbox:
                    InboxListView()
                case .iCloudDrive:
                    SideLoadedEpisodesView(modelContainer: ModelContainerManager.shared.container)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct InboxListView: View {

    @State private var episodes: [Episode] = []
    @State private var isClearingInbox = false
    @State private var hasLoaded = false
    @State private var loadGeneration = 0

    @State private var errorMessage: String?
    @State private var liveNotificationFeed: URL?
    @State private var showLiveNotificationPodcast = false
    @Environment(\.modelContext) private var modelContext
    @State private var refreshProgress = PodcastRefreshCoordinator.shared.progress
    @Query private var podcasts: [Podcast]

    init() {
        _podcasts = Query(sort: [SortDescriptor<Podcast>(\.title)])
    }

    private var liveNotificationPodcast: Podcast? {
        guard let feed = liveNotificationFeed else { return nil }
        return podcasts.first { $0.feed == feed }
    }

    var body: some View {
        VStack(spacing: 0) {
            LivePodcastSectionView()

            Group {
            if !hasLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if episodes.isEmpty {
                if refreshProgress.isRefreshing {
                    InboxRefreshPlaceholderView(
                        completed: refreshProgress.completed,
                        total: refreshProgress.total
                    )
                } else {
                    InboxEmptyView()
                }
            } else {
                List {
                    ForEach(episodes, id: \.persistentModelID) { episode in
                        ZStack{
                            EpisodeRowView(
                                episode: episode,
                                showsRemoveFromInboxAction: true
                            )
                            NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                                EmptyView()
                            }.opacity(0)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open episode \(episode.title)")
                        .accessibilityHint("Opens this episode details screen")
                        .swipeActions(edge: .trailing){
                            Button(role: .none) {
                                Task { @MainActor in
                                    await removeFromInbox(episode)
                                    await loadEpisodes()
                                }
                            } label: {
                                Label("Remove from Inbox", systemImage: "tray.and.arrow.up.fill")
                            }
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0,
                                             leading: 0,
                                             bottom: 0,
                                             trailing: 0))
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await refreshEpisodes()
                    await loadEpisodes()
                }
            }
            }
        }
        .navigationTitle("Inbox")
        .task {
            if !hasLoaded {
                await loadEpisodes()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .inboxDidChange)) { _ in
            Task { await loadEpisodes() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .livePodcastNotificationTapped)) { notification in
            guard let feedString = notification.userInfo?["podcastFeed"] as? String,
                  let feed = URL(string: feedString),
                  podcasts.contains(where: { $0.feed == feed }) else { return }
            liveNotificationFeed = feed
            showLiveNotificationPodcast = true
        }
        .onReceive(PodcastRefreshCoordinator.shared.progressPublisher) { progress in
            refreshProgress = progress
        }
        // A screen that was off-screen while the run started may have missed the
        // announcement, so re-read the snapshot every time it comes back.
        .onAppear {
            refreshProgress = PodcastRefreshCoordinator.shared.progress
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    Task {
                        await refreshEpisodes()
                        await loadEpisodes()
                    }
                }) {
                    if refreshProgress.isRefreshing {
                        if refreshProgress.total != 0 {
                            CircularProgressView(
                                value: Double(refreshProgress.completed),
                                total: Double(refreshProgress.total)
                            )
                        } else {
                            ProgressView()
                        }
                    }else{
                        Label("Refresh Inbox", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(refreshProgress.isRefreshing)
                .accessibilityLabel(refreshProgress.isRefreshing ? "Refreshing inbox" : "Refresh inbox")
                .accessibilityHint("Fetches new episodes and reloads your inbox")
                .accessibilityInputLabels([Text("Refresh inbox"), Text("Update inbox")])
            }

            if !episodes.isEmpty {
                ToolbarItem(placement: .secondaryAction) {
                    Button(action: {
                        Task {
                            await clearInbox()
                            await loadEpisodes()
                        }
                    }) {
                        if isClearingInbox {
                            ProgressView()
                        }else{
                            Label("Clear inbox", systemImage: "tray.and.arrow.up")
                        }
                    }
                    .disabled(isClearingInbox)
                    .accessibilityLabel(isClearingInbox ? "Clearing inbox" : "Clear inbox")
                    .accessibilityHint("Removes every episode from the inbox without changing playlists or archive state")
                    .accessibilityInputLabels([Text("Clear inbox"), Text("Remove all inbox episodes")])
                }
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            if let errorMessage = errorMessage {
                Text(errorMessage)
            }
        }
        .overlay {
            if let liveNotificationPodcast {
                NavigationLink(
                    destination: PodcastDetailView(podcast: liveNotificationPodcast),
                    isActive: $showLiveNotificationPodcast
                ) {
                    EmptyView()
                }
                .hidden()
            }
        }
    }

    // MARK: - Data Loading

    private func loadEpisodes() async {
        loadGeneration += 1
        let generation = loadGeneration
        let actor = EpisodeListQueryActor(modelContainer: modelContext.container)

        do {
            let episodeIDs = try await actor.inboxEpisodeIDs()
            guard Task.isCancelled == false, generation == loadGeneration else {
                return
            }
            // A refresh publishes new episodes every second or so. Reassigning an
            // unchanged list would reset the rows the user is currently swiping.
            if episodeIDs != episodes.map(\.persistentModelID) {
                let episodesByID: [PersistentIdentifier: Episode] = modelContext.existingModels(
                    for: episodeIDs
                )
                episodes = episodeIDs.compactMap { episodesByID[$0] }
            }
            hasLoaded = true
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = "Failed to load episodes: \(error.localizedDescription)"
            hasLoaded = true
        }
    }
    
    private func removeFromInbox(_ episode: Episode) async {
        let episodeActor = EpisodeActor(modelContainer: modelContext.container)
        await episodeActor.removeFromInbox(episode.url)
    }
    
    private func clearInbox() async {
        isClearingInbox = true
        let episodeURLs = episodes.map { $0.url }
        let episodeActor = PodcastModelActor(modelContainer: modelContext.container)
        await episodeActor.removeEpisodesFromInbox(episodeURLs: episodeURLs)
        isClearingInbox = false
    }
    
    private func refreshEpisodes() async {
        errorMessage = nil
        await PodcastRefreshCoordinator.shared.refreshAllPodcasts(
            modelContainer: modelContext.container
        )
        errorMessage = PodcastRefreshCoordinator.shared.progress.errorMessage
    }
}

private struct LivePodcastSectionView: View {
    @Query private var subscribedPodcasts: [Podcast]
    @Query(filter: PodcastSettingsView.defaultSettingsFilter)
    private var defaultSettings: [PodcastSettings]

    init() {
        _subscribedPodcasts = Query(
            filter: #Predicate<Podcast> { $0.metaData?.isSubscribed != false },
            sort: [SortDescriptor<Podcast>(\.title)]
        )
    }

    private var visibleItems: [(podcast: Podcast, item: PodcastLiveItem)] {
        guard defaultSettings.first?.showLivePodcasts != false else { return [] }
        return subscribedPodcasts.flatMap { podcast in
            podcast.liveItems
                .filter { $0.status == .live || $0.isUpcoming }
                .map { (podcast: podcast, item: $0) }
        }
        .sorted { lhs, rhs in
            if lhs.item.status != rhs.item.status {
                return lhs.item.status == .live
            }
            return (lhs.item.start ?? .distantFuture) < (rhs.item.start ?? .distantFuture)
        }
    }

    var body: some View {
        if visibleItems.isEmpty == false {
            VStack(alignment: .leading, spacing: 8) {
                Label("Live Podcasts", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                    .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(visibleItems.enumerated()), id: \.offset) { _, entry in
                            LivePodcastCard(
                                podcast: entry.podcast,
                                liveItem: entry.item
                            )
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 10)
                }
            }
            .padding(.top, 8)
            .background(.thinMaterial)
        }
    }
}

private struct LivePodcastCard: View {
    let podcast: Podcast
    let liveItem: PodcastLiveItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverImageView(imageURL: liveItem.artworkURL ?? podcast.imageURL)
                .frame(width: 86, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(liveItem.status == .live ? "LIVE" : "UPCOMING")
                .font(.caption2.weight(.bold))
                .foregroundStyle(liveItem.status == .live ? .red : .secondary)

            Text(liveItem.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)

            Text(podcast.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if liveItem.status == .live, liveItem.preferredStream != nil {
                Button {
                    Task {
                        await Player.shared.playLiveItem(
                            liveItem,
                            podcastTitle: podcast.title,
                            artworkURL: liveItem.artworkURL ?? podcast.imageURL,
                            link: liveItem.link
                        )
                    }
                } label: {
                    Label("Listen Live", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else if let start = liveItem.start {
                Text(start, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 150, alignment: .leading)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(liveItem.status == .live ? "Live" : "Upcoming") \(liveItem.title), \(podcast.title)")
    }
}



#Preview {
    NavigationView {
        InboxView()
    }
} 
