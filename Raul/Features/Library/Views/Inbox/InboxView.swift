import SwiftUI
import SwiftData

extension Notification.Name {
    static let inboxDidChange = Notification.Name("inboxDidChange")
}

enum InboxSection: String, CaseIterable, Identifiable {
    case inbox
    case saved
    case favorites
    case iCloudDrive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox:
            return "Inbox"
        case .saved:
            return "Saved"
        case .favorites:
            return "Favorites"
        case .iCloudDrive:
            return "Sideloading"
        }
    }
}

struct InboxView: View {
    @State private var selectedSection: InboxSection = .inbox

    var body: some View {
        VStack(spacing: 12) {
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
                case .saved:
                    TriageEpisodeListView(savedForLater: true)
                case .favorites:
                    TriageEpisodeListView(savedForLater: false)
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
    @State private var showClearInboxConfirmation = false
    @State private var hasLoaded = false
    @State private var loadGeneration = 0

    @State private var errorMessage: String?
    @State private var liveNotificationFeed: URL?
    @State private var showLiveNotificationPodcast = false
    @State private var undoTriage: InboxTriageUndo?
#if DEBUG
    @State private var showReleaseCalendar = false
#endif
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
                    ForEach(Array(episodes.enumerated()), id: \.element.persistentModelID) { index, episode in
                        ZStack{
                            EpisodeRowView(
                                episode: episode,
                                showsRemoveFromInboxAction: true,
                                groupPosition: EpisodeRowGroupPosition(index: index, count: episodes.count)
                            )
                            NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                                EmptyView()
                            }.opacity(0)
                        }
                        .buttonStyle(.plain)
                        .episodeRowSwipeActions(for: episode)
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
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                Task { await updateTriage(episode, savedForLater: episode.metaData?.isSavedForLater != true, favorite: nil) }
                            } label: {
                                Label(
                                    episode.metaData?.isSavedForLater == true ? "Remove Saved" : "Save for Later",
                                    systemImage: episode.metaData?.isSavedForLater == true ? "bookmark.slash" : "bookmark"
                                )
                            }
                            .tint(.indigo)
                            Button {
                                Task { await updateTriage(episode, savedForLater: nil, favorite: episode.metaData?.isFavorite != true) }
                            } label: {
                                Label(
                                    episode.metaData?.isFavorite == true ? "Unfavorite" : "Favorite",
                                    systemImage: episode.metaData?.isFavorite == true ? "heart.slash" : "heart"
                                )
                            }
                            .tint(.pink)
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
#if DEBUG
            ToolbarItem(placement: .navigation) {
                Button {
                    showReleaseCalendar = true
                } label: {
                    Label("Release prediction", systemImage: "calendar")
                }
                .accessibilityHint("Shows predicted release dates for subscribed podcasts")
            }
#endif
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
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        showClearInboxConfirmation = true
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
        .overlay(alignment: .top) {
            if let undoTriage {
                HStack {
                    Text(undoTriage.message)
                        .font(.subheadline)
                    Spacer()
                    Button("Undo") {
                        Task { await undoLastTriage() }
                    }
                    .fontWeight(.semibold)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .padding(.horizontal)
                .padding(.top, 8)
                .accessibilityElement(children: .contain)
            }
        }
        .confirmationDialog("Clear inbox?", isPresented: $showClearInboxConfirmation, titleVisibility: .visible) {
            Button("Clear inbox", role: .destructive) {
                Task {
                    await clearInbox()
                    await loadEpisodes()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove all \(episodes.count) episodes from Inbox? They remain in your library and playlists, and are not marked played.")
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
#if DEBUG
        .sheet(isPresented: $showReleaseCalendar) {
            NavigationStack {
                DebugReleaseCalendarView(podcasts: podcasts)
            }
        }
#endif
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

    private func updateTriage(_ episode: Episode, savedForLater: Bool?, favorite: Bool?) async {
        guard let url = episode.url else { return }
        let previousSaved = episode.metaData?.isSavedForLater == true
        let previousFavorite = episode.metaData?.isFavorite == true
        let actor = EpisodeActor(modelContainer: modelContext.container)
        await actor.setTriageFlag(episodeURL: url, savedForLater: savedForLater, favorite: favorite)
        if let savedForLater, previousSaved != savedForLater {
            undoTriage = InboxTriageUndo(url: url, title: episode.title, flag: .saved, previousValue: previousSaved)
        } else if let favorite, previousFavorite != favorite {
            undoTriage = InboxTriageUndo(url: url, title: episode.title, flag: .favorite, previousValue: previousFavorite)
        }
    }

    private func undoLastTriage() async {
        guard let undoTriage else { return }
        let actor = EpisodeActor(modelContainer: modelContext.container)
        switch undoTriage.flag {
        case .saved:
            await actor.setTriageFlag(episodeURL: undoTriage.url, savedForLater: undoTriage.previousValue)
        case .favorite:
            await actor.setTriageFlag(episodeURL: undoTriage.url, favorite: undoTriage.previousValue)
        }
        self.undoTriage = nil
    }
    
    private func clearInbox() async {
        isClearingInbox = true
        let episodeURLs = episodes.map { $0.url }
        let episodeActor = PodcastModelActor(modelContainer: modelContext.container)
        do {
            try await episodeActor.removeEpisodesFromInbox(episodeURLs: episodeURLs)
        } catch {
            errorMessage = "Failed to clear inbox: \(error.localizedDescription)"
        }
        isClearingInbox = false
    }
    
    private func refreshEpisodes() async {
        errorMessage = nil
        await PodcastRefreshCoordinator.shared.refreshAllPodcasts(
            modelContainer: modelContext.container
        )
        // Per-feed failures are persisted on PodcastMetaData and shown on each
        // podcast row. Keep the inbox alert for inbox loading/maintenance errors.
    }
}

private enum InboxTriageFlag {
    case saved, favorite
}

private struct InboxTriageUndo {
    let url: URL
    let title: String
    let flag: InboxTriageFlag
    let previousValue: Bool
    var message: String {
        switch flag {
        case .saved: "Saved for Later: \(title)"
        case .favorite: "Favorite updated: \(title)"
        }
    }
}

private struct TriageEpisodeListView: View {
    let savedForLater: Bool
    @Environment(\.modelContext) private var modelContext
    @State private var episodes: [Episode] = []

    private var title: String { savedForLater ? "Saved for Later" : "Favorites" }

    var body: some View {
        Group {
            if episodes.isEmpty {
                ContentUnavailableView(
                    savedForLater ? "No Saved Episodes" : "No Favorite Episodes",
                    systemImage: savedForLater ? "bookmark" : "heart",
                    description: Text(savedForLater
                        ? "Save an Inbox episode to keep it here without adding it to Up Next."
                        : "Favorite episodes from Inbox or episode actions to find them here.")
                )
            } else {
                List(Array(episodes.enumerated()), id: \.element.persistentModelID) { index, episode in
                    ZStack {
                        EpisodeRowView(
                            episode: episode,
                            groupPosition: EpisodeRowGroupPosition(index: index, count: episodes.count)
                        )
                        NavigationLink(destination: EpisodeDetailView(episode: episode)) { EmptyView() }
                            .opacity(0)
                    }
                    .episodeRowSwipeActions(for: episode)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            Task {
                                await EpisodeActor(modelContainer: modelContext.container).setTriageFlag(
                                    episodeURL: episode.url,
                                    savedForLater: savedForLater ? false : nil,
                                    favorite: savedForLater ? nil : false
                                )
                            }
                        } label: {
                            Label(savedForLater ? "Remove Saved" : "Unfavorite", systemImage: "xmark")
                        }
                        .tint(.secondary)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .inboxDidChange)) { _ in
            Task { await load() }
        }
    }

    private func load() async {
        do {
            let ids = try await EpisodeListQueryActor(modelContainer: modelContext.container)
                .triageEpisodeIDs(savedForLater: savedForLater)
            let byID: [PersistentIdentifier: Episode] = modelContext.existingModels(for: ids)
            episodes = ids.compactMap { byID[$0] }
        } catch {
            episodes = []
        }
    }
}



#Preview {
    NavigationView {
        InboxView()
    }
} 
