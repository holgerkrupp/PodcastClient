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
    @State private var grouping: InboxGrouping = .none
    @State private var editMode: EditMode = .inactive
    @State private var selectedEpisodeKeys: Set<String> = []
    @State private var isPerformingTriage = false
    @State private var showCleanupSettings = false
    @State private var cleanupPreviewCount = 0
    @State private var isLoadingCleanupPreview = false
    @AppStorage("inbox.cleanup.mode") private var cleanupMode = "never"
    @AppStorage("inbox.cleanup.days") private var cleanupDays = 30
    @AppStorage("inbox.cleanup.keepLatest") private var cleanupKeepLatest = 10
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
    @Environment(\.episodeControlPlaylists) private var playlists

    init() {
        _podcasts = Query(sort: [SortDescriptor<Podcast>(\.title)])
    }

    private var liveNotificationPodcast: Podcast? {
        guard let feed = liveNotificationFeed else { return nil }
        return podcasts.first { $0.feed == feed }
    }

    private var episodeByStableIdentity: [String: Episode] {
        Dictionary(uniqueKeysWithValues: episodes.map { ($0.stableEpisodeIdentityKey, $0) })
    }

    private var projections: [InboxEpisodeProjection] {
        episodes.map { episode in
            InboxEpisodeProjection(
                id: episode.stableEpisodeIdentityKey,
                title: episode.title,
                podcastKey: episode.podcast?.stablePodcastIdentityKey ?? "sideloaded",
                podcastTitle: episode.displayPodcastTitle ?? "Sideloaded",
                publishedAt: episode.publishDate,
                remainingDuration: max(0, episode.displayRemainingTime ?? episode.duration ?? 0),
                isSavedForLater: episode.metaData?.isSavedForLater == true,
                isFavorite: episode.metaData?.isFavorite == true,
                // Queue membership is intentionally not read by each row. The
                // cleanup preview asks the actor for its one batched snapshot.
                isQueued: false,
                isDownloaded: false,
                hasPlaybackHistory: false
            )
        }
    }

    private var groupedEpisodes: [InboxEpisodeGroup] {
        InboxEpisodeProjection.groups(from: projections, grouping: grouping)
    }

    private var selectedEpisodes: [Episode] {
        selectedEpisodeKeys.compactMap { episodeByStableIdentity[$0] }
    }

    private var selectedCount: Int { selectedEpisodes.count }

    private var configuredCleanupPolicy: InboxCleanupPolicy {
        switch cleanupMode {
        case "olderThanDays":
            return .olderThanDays(max(1, cleanupDays))
        case "keepLatestPerPodcast":
            return .keepLatestPerPodcast(max(0, cleanupKeepLatest))
        default:
            return .never
        }
    }

    private var selectedPlaylistTitle: String {
        guard let id = UUID(uuidString: UserDefaults.standard.string(forKey: PlaylistPreferenceKeys.selectedPlaylistID) ?? ""),
              let playlist = playlists.first(where: { $0.id == id }) else {
            return Playlist.defaultQueueDisplayName
        }
        return playlist.title
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
                List(selection: $selectedEpisodeKeys) {
                    ForEach(groupedEpisodes) { group in
                        Section {
                            ForEach(Array(group.episodes.enumerated()), id: \.element.id) { index, projection in
                                if let episode = episodeByStableIdentity[projection.id] {
                                    inboxRow(
                                        episode,
                                        projection: projection,
                                        groupPosition: EpisodeRowGroupPosition(
                                            index: index,
                                            count: group.episodes.count
                                        )
                                    )
                                }
                            }
                        } header: {
                            InboxGroupHeader(group: group, grouping: grouping)
                        }
                    }
                }
                .listStyle(.plain)
                .environment(\.editMode, $editMode)
                .animation(.default, value: grouping)
                .animation(.default, value: selectedEpisodeKeys)
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
        .onChange(of: episodes.map(\.stableEpisodeIdentityKey)) { _, keys in
            selectedEpisodeKeys.formIntersection(keys)
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
                    if editMode == .active {
                        Menu {
                            Button {
                                Task { await performTriage(.save, on: selectedEpisodes) }
                            } label: {
                                Label("Save for Later", systemImage: "bookmark")
                            }
                            .disabled(selectedCount == 0 || isPerformingTriage)

                            Button {
                                Task { await performTriage(.queue, on: selectedEpisodes) }
                            } label: {
                                Label("Add to \(selectedPlaylistTitle)", systemImage: "text.line.last.and.arrowtriangle.forward")
                            }
                            .disabled(selectedCount == 0 || isPerformingTriage)

                            Button {
                                Task { await performTriage(.playNext, on: selectedEpisodes) }
                            } label: {
                                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            .disabled(selectedCount == 0 || isPerformingTriage)

                            Button {
                                Task { await performTriage(.playLast, on: selectedEpisodes) }
                            } label: {
                                Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
                            }
                            .disabled(selectedCount == 0 || isPerformingTriage)

                            Button {
                                Task { await performTriage(.markPlayed, on: selectedEpisodes) }
                            } label: {
                                Label("Mark Played", systemImage: "checkmark.circle")
                            }
                            .disabled(selectedCount == 0 || isPerformingTriage)

                            Divider()

                            Button(role: .destructive) {
                                Task { await performTriage(.dismiss, on: selectedEpisodes) }
                            } label: {
                                Label("Dismiss from Inbox", systemImage: "tray.and.arrow.up")
                            }
                            .disabled(selectedCount == 0 || isPerformingTriage)
                        } label: {
                            Label(
                                selectedCount == 0 ? "Actions" : "Actions (\(selectedCount))",
                                systemImage: "ellipsis.circle"
                            )
                        }
                        .disabled(selectedCount == 0 || isPerformingTriage)
                        Button("Select All", systemImage: "checkmark.circle") {
                            selectedEpisodeKeys = Set(episodes.map(\.stableEpisodeIdentityKey))
                            editMode = .active
                        }
                    } else {
                        EditButton()
                            .disabled(isPerformingTriage)
                    }
                }

                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        Menu("Group by", systemImage: "rectangle.3.group") {
                            Picker("Group by", selection: $grouping) {
                                ForEach(InboxGrouping.allCases) { option in
                                    Text(option.title).tag(option)
                                }
                            }
                        }
                        Button("Inbox cleanup", systemImage: "line.3.horizontal.decrease.circle") {
                            showCleanupSettings = true
                        }
                        Divider()
                        Button("Clear inbox", systemImage: "tray.and.arrow.up", role: .destructive) {
                            showClearInboxConfirmation = true
                        }
                    } label: {
                        Label("Inbox options", systemImage: "ellipsis.circle")
                    }
                    .disabled(isClearingInbox || isPerformingTriage)
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
        .sheet(isPresented: $showCleanupSettings) {
            InboxCleanupEditor(
                cleanupMode: $cleanupMode,
                cleanupDays: $cleanupDays,
                cleanupKeepLatest: $cleanupKeepLatest,
                previewCount: cleanupPreviewCount,
                isLoadingPreview: isLoadingCleanupPreview,
                onPreview: { Task { await previewCleanup() } },
                onApply: { Task { await applyCleanup() } }
            )
            .task { await previewCleanup() }
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

    @ViewBuilder
    private func inboxRow(
        _ episode: Episode,
        projection: InboxEpisodeProjection,
        groupPosition: EpisodeRowGroupPosition
    ) -> some View {
        ZStack {
            EpisodeRowView(
                episode: episode,
                showsRemoveFromInboxAction: true,
                groupPosition: groupPosition
            )
            NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                EmptyView()
            }
            .opacity(0)
        }
        .buttonStyle(.plain)
        .tag(projection.id)
        .episodeRowSwipeActions(for: episode)
        .accessibilityLabel("Open episode \(episode.title)")
        .accessibilityHint(editMode == .active ? "Selects this episode for batch actions" : "Opens this episode details screen")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await performTriage(.dismiss, on: [episode]) }
            } label: {
                Label("Dismiss from Inbox", systemImage: "tray.and.arrow.up.fill")
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
        .contextMenu {
            Button {
                Task { await performTriage(.playNext, on: [episode]) }
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button {
                Task { await performTriage(.playLast, on: [episode]) }
            } label: {
                Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            Divider()
            Button {
                Task { await addToSelectedPlaylist(episode) }
            } label: {
                Label("Add to \(selectedPlaylistTitle)", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            Button {
                Task { await updateTriage(episode, savedForLater: episode.metaData?.isSavedForLater != true, favorite: nil) }
            } label: {
                Label(
                    episode.metaData?.isSavedForLater == true ? "Remove Saved" : "Save for Later",
                    systemImage: episode.metaData?.isSavedForLater == true ? "bookmark.slash" : "bookmark"
                )
            }
            Button {
                Task { await updateTriage(episode, savedForLater: nil, favorite: episode.metaData?.isFavorite != true) }
            } label: {
                Label(
                    episode.metaData?.isFavorite == true ? "Unfavorite" : "Favorite",
                    systemImage: episode.metaData?.isFavorite == true ? "heart.slash" : "heart"
                )
            }
            Divider()
            Button {
                Task { await performTriage(.markPlayed, on: [episode]) }
            } label: {
                Label("Mark Played", systemImage: "checkmark.circle")
            }
            Button(role: .destructive) {
                Task { await performTriage(.dismiss, on: [episode]) }
            } label: {
                Label("Dismiss from Inbox", systemImage: "tray.and.arrow.up")
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
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
    
    private func updateTriage(_ episode: Episode, savedForLater: Bool?, favorite: Bool?) async {
        guard let url = episode.url else { return }
        let previousInbox = episode.metaData?.isInbox == true
        let previousSaved = episode.metaData?.isSavedForLater == true
        let previousFavorite = episode.metaData?.isFavorite == true
        let resultSaved = savedForLater ?? previousSaved
        let resultFavorite = favorite ?? previousFavorite
        let actor = EpisodeActor(modelContainer: modelContext.container)
        await actor.setTriageFlag(episodeURL: url, savedForLater: savedForLater, favorite: favorite)
        if previousSaved != resultSaved || previousFavorite != resultFavorite {
            undoTriage = InboxTriageUndo(
                changes: [InboxTriageChange(
                    episodeURL: url,
                    previousInbox: previousInbox,
                    previousSavedForLater: previousSaved,
                    previousFavorite: previousFavorite,
                    resultInbox: previousInbox,
                    resultSavedForLater: resultSaved,
                    resultFavorite: resultFavorite
                )],
                message: resultSaved != previousSaved ? "Saved for Later updated" : "Favorite updated"
            )
        }
        await loadEpisodes()
    }

    private func undoLastTriage() async {
        guard let undoTriage else { return }
        let actor = EpisodeActor(modelContainer: modelContext.container)
        await actor.undoTriageChanges(undoTriage.changes)
        self.undoTriage = nil
        await loadEpisodes()
    }

    private func performTriage(_ action: InboxTriageAction, on episodes: [Episode]) async {
        let episodes = Array(Dictionary(uniqueKeysWithValues: episodes.compactMap { episode in
            episode.url.map { ($0, episode) }
        }).values)
        guard episodes.isEmpty == false else { return }

        isPerformingTriage = true
        defer { isPerformingTriage = false }
        let urls = episodes.compactMap(\.url)
        let actor = EpisodeActor(modelContainer: modelContext.container)

        do {
            switch action {
            case .save:
                let changes = triageChanges(for: episodes, resultSavedForLater: true)
                await actor.setTriageFlags(episodeURLs: urls, savedForLater: true)
                undoTriage = InboxTriageUndo(
                    changes: changes,
                    message: "Saved \(episodes.count) episode\(episodes.count == 1 ? "" : "s") for later"
                )
            case .favorite:
                let changes = triageChanges(for: episodes, resultFavorite: true)
                await actor.setTriageFlags(episodeURLs: urls, favorite: true)
                undoTriage = InboxTriageUndo(
                    changes: changes,
                    message: "Favorited \(episodes.count) episode\(episodes.count == 1 ? "" : "s")"
                )
            case .dismiss:
                let changes = triageChanges(for: episodes, resultInbox: false)
                try await actor.removeEpisodesFromInbox(episodeURLs: urls)
                undoTriage = InboxTriageUndo(
                    changes: changes,
                    message: "Dismissed \(episodes.count) episode\(episodes.count == 1 ? "" : "s")"
                )
            case .markPlayed:
                await actor.markEpisodesAsPlayed(urls)
                undoTriage = nil
            case .queue:
                let playlistID = try Playlist.resolvedSelectedManualPlaylistID(in: modelContext)
                let playlistActor = try PlaylistModelActor(
                    modelContainer: modelContext.container,
                    playlistID: playlistID
                )
                var failures = 0
                for url in urls {
                    do {
                        _ = try await playlistActor.appendIfAbsent(episodeURL: url)
                    } catch {
                        failures += 1
                    }
                }
                if failures > 0 {
                    errorMessage = "Added \(episodes.count - failures) episode\(episodes.count - failures == 1 ? "" : "s"). \(failures) could not be queued."
                }
                undoTriage = nil
            case .playNext, .playLast:
                let position: Playlist.Position = action == .playNext ? .front : .end
                let orderedEpisodes = position == .front ? Array(episodes.reversed()) : episodes
                let playlistID = try Playlist.resolvedSelectedManualPlaylistID(in: modelContext)
                let playlistActor = try PlaylistModelActor(
                    modelContainer: modelContext.container,
                    playlistID: playlistID
                )
                var failures = 0
                for episode in orderedEpisodes {
                    guard let url = episode.url else { failures += 1; continue }
                    do {
                        if position == .front {
                            try await playlistActor.insert(
                                episodeURL: url,
                                after: Player.shared.currentEpisodeURL
                            )
                        } else {
                            try await playlistActor.add(episodeURL: url, to: .end)
                        }
                    } catch {
                        failures += 1
                    }
                }
                if failures > 0 {
                    let succeeded = episodes.count - failures
                    errorMessage = "Queued \(succeeded) episode\(succeeded == 1 ? "" : "s"). \(failures) could not be added."
                }
                undoTriage = nil
            }
        } catch {
            errorMessage = "Could not update the selected episodes. Your existing Inbox state was kept where the operation did not finish."
        }

        selectedEpisodeKeys.removeAll()
        editMode = .inactive
        await loadEpisodes()
    }

    private func triageChanges(
        for episodes: [Episode],
        resultInbox: Bool? = nil,
        resultSavedForLater: Bool? = nil,
        resultFavorite: Bool? = nil
    ) -> [InboxTriageChange] {
        episodes.compactMap { episode in
            guard let url = episode.url else { return nil }
            let previousInbox = episode.metaData?.isInbox == true
            let previousSaved = episode.metaData?.isSavedForLater == true
            let previousFavorite = episode.metaData?.isFavorite == true
            return InboxTriageChange(
                episodeURL: url,
                previousInbox: previousInbox,
                previousSavedForLater: previousSaved,
                previousFavorite: previousFavorite,
                resultInbox: resultInbox ?? previousInbox,
                resultSavedForLater: resultSavedForLater ?? previousSaved,
                resultFavorite: resultFavorite ?? previousFavorite
            )
        }
    }

    private func addToSelectedPlaylist(_ episode: Episode) async {
        guard let url = episode.url else { return }
        do {
            let playlistID = try Playlist.resolvedSelectedManualPlaylistID(in: modelContext)
            let actor = try PlaylistModelActor(
                modelContainer: modelContext.container,
                playlistID: playlistID
            )
            _ = try await actor.appendIfAbsent(episodeURL: url)
            await loadEpisodes()
        } catch {
            errorMessage = "Could not add the episode to the selected playlist."
        }
    }

    private func previewCleanup() async {
        isLoadingCleanupPreview = true
        defer { isLoadingCleanupPreview = false }
        do {
            let actor = EpisodeActor(modelContainer: modelContext.container)
            cleanupPreviewCount = try await actor.inboxCleanupCandidates(
                episodeURLs: episodes.compactMap(\.url),
                policy: configuredCleanupPolicy
            ).count
        } catch {
            cleanupPreviewCount = 0
            errorMessage = "Could not preview Inbox cleanup."
        }
    }

    private func applyCleanup() async {
        guard configuredCleanupPolicy.isEnabled else { return }
        isPerformingTriage = true
        defer { isPerformingTriage = false }
        do {
            let actor = EpisodeActor(modelContainer: modelContext.container)
            let urls = try await actor.inboxCleanupCandidates(
                episodeURLs: episodes.compactMap(\.url),
                policy: configuredCleanupPolicy
            )
            guard urls.isEmpty == false else {
                cleanupPreviewCount = 0
                return
            }
            let changes = triageChanges(
                for: episodes.filter { episode in
                    guard let url = episode.url else { return false }
                    return urls.contains(url)
                },
                resultInbox: false
            )
            try await actor.removeEpisodesFromInbox(episodeURLs: urls)
            undoTriage = InboxTriageUndo(
                changes: changes,
                message: "Dismissed \(urls.count) safe cleanup candidate\(urls.count == 1 ? "" : "s")"
            )
            showCleanupSettings = false
            await loadEpisodes()
        } catch {
            errorMessage = "Could not apply Inbox cleanup. No episodes were deleted."
        }
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

private enum InboxTriageAction {
    case dismiss
    case save
    case favorite
    case markPlayed
    case queue
    case playNext
    case playLast
}

private struct InboxTriageUndo {
    let changes: [InboxTriageChange]
    let message: String
}

private struct InboxGroupHeader: View {
    let group: InboxEpisodeGroup
    let grouping: InboxGrouping

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(group.title)
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text("\(group.episodes.count) episode\(group.episodes.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if group.remainingDuration > 0 {
                Text(Duration.seconds(group.remainingDuration).formatted(.units(width: .narrow)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(Duration.seconds(group.remainingDuration).formatted(.units(width: .wide))) remaining")
            }
        }
        .textCase(nil)
        .padding(.horizontal, 4)
        .padding(.top, grouping == .none ? 4 : 12)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct InboxCleanupEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var cleanupMode: String
    @Binding var cleanupDays: Int
    @Binding var cleanupKeepLatest: Int
    let previewCount: Int
    let isLoadingPreview: Bool
    let onPreview: () -> Void
    let onApply: () -> Void

    private var isEnabled: Bool { cleanupMode != "never" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Rule", selection: $cleanupMode) {
                        Text("Never").tag("never")
                        Text("Older than…").tag("olderThanDays")
                        Text("Keep latest per podcast").tag("keepLatestPerPodcast")
                    }
                    if cleanupMode == "olderThanDays" {
                        Stepper("Older than \(cleanupDays) days", value: $cleanupDays, in: 1...365)
                    }
                    if cleanupMode == "keepLatestPerPodcast" {
                        Stepper("Keep latest \(cleanupKeepLatest)", value: $cleanupKeepLatest, in: 0...100)
                    }
                } header: {
                    Text("Safe Inbox cleanup")
                } footer: {
                    Text("Cleanup is off by default. It only dismisses pending Inbox episodes and never touches saved, favorite, queued, downloaded, started, or played items.")
                }

                Section("Preview") {
                    if isLoadingPreview {
                        ProgressView("Checking eligible episodes…")
                    } else if isEnabled {
                        Text("\(previewCount) episode\(previewCount == 1 ? "" : "s") would be dismissed")
                            .accessibilityValue(previewCount.formatted())
                    } else {
                        Text("Cleanup is disabled")
                            .foregroundStyle(.secondary)
                    }
                    Button("Refresh preview", action: onPreview)
                        .disabled(isLoadingPreview)
                }

                if isEnabled {
                    Section {
                        Button("Dismiss eligible episodes", role: .destructive, action: onApply)
                            .disabled(previewCount == 0 || isLoadingPreview)
                    } footer: {
                        Text("This is reversible with Undo as long as those episodes have not changed elsewhere.")
                    }
                }
            }
            .navigationTitle("Inbox cleanup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: cleanupMode) { _, _ in onPreview() }
            .onChange(of: cleanupDays) { _, _ in onPreview() }
            .onChange(of: cleanupKeepLatest) { _, _ in onPreview() }
        }
    }
}

struct TriageEpisodeListView: View {
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
                        ? "Save an episode for later to keep it here without adding it to Up Next."
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
