//
//  PlaylistView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import SwiftUI
import SwiftData
import TipKit

struct PlaylistView: View {
    @Query(sort: [SortDescriptor(\Playlist.sortIndex, order: .forward), SortDescriptor(\Playlist.title, order: .forward)])
    private var playlists: [Playlist]
    @Query(
        filter: #Predicate<Podcast> { $0.metaData?.isSubscribed != false },
        sort: [SortDescriptor<Podcast>(\.title)]
    )
    private var subscribedPodcasts: [Podcast]
    @Query(filter: PodcastSettingsView.defaultSettingsFilter)
    private var defaultSettings: [PodcastSettings]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openPodcastSettings) private var openSettings
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @AppStorage(PlaylistPreferenceKeys.selectedPlaylistID) private var storedPlaylistID: String = ""
    @Binding var requestedEpisodeURL: URL?

    @State private var selectedPlaylistID: String = ""
    @State private var showCreatePlaylistSheet: Bool = false
    @State private var requestedEpisode: Episode?
    @State private var showsRequestedEpisode = false
    @State private var showsLivePodcasts = false

    private var visiblePlaylists: [Playlist] {
        Playlist.visibleSorted(playlists)
    }

    private var selectedPlaylist: Playlist? {
        let candidateIDs = [selectedPlaylistID, storedPlaylistID]
            .compactMap(UUID.init(uuidString:))

        for candidateID in candidateIDs {
            if let playlist = visiblePlaylists.first(where: { $0.id == candidateID }) {
                return playlist
            }
        }

        // `selectedPlaylistID` is view-local state and starts empty on every
        // launch. Resolve the persisted/default playlist synchronously for the
        // first frame instead of briefly rendering the no-selection branch.
        return visiblePlaylists.first(where: { $0.title == Playlist.defaultQueueTitle })
            ?? visiblePlaylists.first
    }

    /// On a regular-width scene, the playlist picker belongs to the episode
    /// list it changes. Keeping it in the content header also leaves the
    /// trailing system bar free to adapt around the fold. Compact scenes keep
    /// the familiar principal toolbar control.
    private var showsPlaylistPickerInContent: Bool {
        horizontalSizeClass == .regular
    }

    private var liveEntries: [LivePodcastEntry] {
        LivePodcastDiscovery.entries(
            from: subscribedPodcasts,
            isEnabled: defaultSettings.first?.showLivePodcasts != false
        )
    }

    var body: some View {
        VStack {
            if showsPlaylistPickerInContent {
                playlistPicker
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            Group {
                if let selectedPlaylist {
                    Group {
                        if selectedPlaylist.isSmartPlaylist {
                            SmartPlaylistPageView(playlist: selectedPlaylist)
                        } else {
                            ManualPlaylistPageView(playlist: selectedPlaylist)
                        }
                    }
                    .id(selectedPlaylist.id)
                } else {
                    PlaylistLaunchPlaceholder()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(reduceMotion ? nil : .easeInOut, value: selectedPlaylistID)
        .platformInlineNavigationTitle()
        .toolbar {
            if liveEntries.isEmpty == false {
                #if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    LivePodcastsToolbarButton {
                        showsLivePodcasts = true
                    }
                }
                #else
                ToolbarItem(placement: .topBarLeading) {
                    LivePodcastsToolbarButton {
                        showsLivePodcasts = true
                    }
                }
                #endif
            }

            if showsPlaylistPickerInContent == false {
                ToolbarItem(placement: .principal) {
                    playlistPicker
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    openSettings()
                }) {
                    Label("Settings", systemImage: "gear")
                }
                .accessibilityLabel("Settings")
                .accessibilityHint("Open settings")
                .accessibilityInputLabels([Text("Settings"), Text("Open settings")])
            }
        }
        .sheet(isPresented: $showCreatePlaylistSheet) {
            NewPlaylistSheet { draft in
                try createPlaylist(from: draft)
            }
        }
        .sheet(isPresented: $showsLivePodcasts) {
            LivePodcastsView()
        }
        .navigationDestination(isPresented: $showsRequestedEpisode) {
            if let requestedEpisode {
                EpisodeDetailView(episode: requestedEpisode)
            }
        }
        .task {
            ensureDefaultPlaylist()
            syncSelectionWithStorage()
            openRequestedEpisodeIfNeeded()
        }
        .onChange(of: visiblePlaylists.map(\.id)) { _, _ in
            ensureSelectionIsValid()
        }
        .onChange(of: selectedPlaylistID) { _, newValue in
            storedPlaylistID = newValue
        }
        .onChange(of: requestedEpisodeURL) { _, _ in
            openRequestedEpisodeIfNeeded()
        }
    }

    private var playlistPicker: some View {
        PlaylistTitleMenu(
            currentTitle: selectedPlaylist?.displayTitle ?? Playlist.defaultQueueDisplayName,
            currentSymbolName: selectedPlaylist?.displaySymbolName ?? Playlist.defaultQueueSymbolName,
            playlists: visiblePlaylists,
            selectedPlaylistID: selectedPlaylist?.id,
            onSelect: { playlist in
                selectPlaylist(playlist)
            },
            onCreate: {
                showCreatePlaylistSheet = true
            }
        )
    }

    private func ensureDefaultPlaylist() {
        _ = Playlist.ensureDefaultQueue(in: modelContext)
    }

    private func syncSelectionWithStorage() {
        if let selectedID = Playlist.resolvePlaylistID(from: storedPlaylistID),
           visiblePlaylists.contains(where: { $0.id == selectedID }) {
            selectedPlaylistID = selectedID.uuidString
            return
        }

        if let defaultPlaylist = visiblePlaylists.first(where: { $0.title == Playlist.defaultQueueTitle })
            ?? visiblePlaylists.first {
            selectedPlaylistID = defaultPlaylist.id.uuidString
            storedPlaylistID = selectedPlaylistID
        }
    }

    private func ensureSelectionIsValid() {
        if let selectedID = UUID(uuidString: selectedPlaylistID),
           visiblePlaylists.contains(where: { $0.id == selectedID }) {
            return
        }

        if let storedID = UUID(uuidString: storedPlaylistID),
           visiblePlaylists.contains(where: { $0.id == storedID }) {
            selectedPlaylistID = storedID.uuidString
            return
        }

        if let defaultPlaylist = visiblePlaylists.first(where: { $0.title == Playlist.defaultQueueTitle })
            ?? visiblePlaylists.first {
            selectedPlaylistID = defaultPlaylist.id.uuidString
            storedPlaylistID = selectedPlaylistID
        }
    }

    private func selectPlaylist(_ playlist: Playlist) {
        selectedPlaylistID = playlist.id.uuidString
        storedPlaylistID = selectedPlaylistID
    }

    private func createPlaylist(from draft: PlaylistCreationDraft) throws {
        let playlist = try PlaylistLibrary.create(
            name: draft.name,
            symbolName: draft.symbolName,
            kind: draft.kind,
            smartFilter: draft.smartFilter,
            in: modelContext
        )
        selectedPlaylistID = playlist.id.uuidString
        storedPlaylistID = selectedPlaylistID
    }

    private func openRequestedEpisodeIfNeeded() {
        guard let requestedEpisodeURL else { return }
        let episodeURL = requestedEpisodeURL
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.url == episodeURL }
        )

        requestedEpisode = try? modelContext.fetch(descriptor).first
        showsRequestedEpisode = requestedEpisode != nil
        self.requestedEpisodeURL = nil
    }
}

private struct PlaylistLaunchPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading playlist…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading playlist")
    }
}

private struct PlaylistTitleMenu: View {
    let currentTitle: String
    let currentSymbolName: String
    let playlists: [Playlist]
    let selectedPlaylistID: UUID?
    let onSelect: (Playlist) -> Void
    let onCreate: () -> Void

    var body: some View {
        Menu {
            ForEach(playlists) { playlist in
                Button {
                    onSelect(playlist)
                } label: {
                    if playlist.id == selectedPlaylistID {
                        HStack {
                            Image(systemName: playlist.displaySymbolName)
                            Text(playlist.displayTitle)
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    } else {
                        Label(playlist.displayTitle, systemImage: playlist.displaySymbolName)
                    }
                }
            }

            Divider()

            Button {
                onCreate()
            } label: {
                Label("New Playlist…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: currentSymbolName)
                    .font(.headline)
                Text(currentTitle)
                    .font(.headline)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current playlist \(currentTitle)")
        .accessibilityHint("Opens playlist picker")
    }
}

private struct ManualPlaylistPageView: View {
    let playlist: Playlist

    @Environment(\.modelContext) private var modelContext
    @Environment(DownloadedFilesManager.self) private var fileManager
    @Query private var playlistEntries: [PlaylistEntry]
    /// Cached value snapshot. Rebuilt only when membership/order, the file
    /// inventory, the playing episode or play state changes — not on every
    /// body pass caused by toolbar, filter or playback-tick invalidation.
    @State private var projection = QueueProjection(entries: [])
    @State private var episodesByIdentity: [String: Episode] = [:]
    @State private var hasBuiltProjection = false
    /// Bumped when hydration publishes or a referenced feed/episode commits,
    /// so a same-ID entry whose episode data changed is re-snapshotted.
    @State private var projectionGeneration = 0
    @State private var recordedEntryCount = 0
    @State private var isSmartShuffling = false
    @State private var smartShuffleMessage: String?
    @State private var filterState = QueueFilterState.all
    @State private var restoreStatus = PlaylistRestoreStatusModel()
    private let reorderTip = ReorderPlaylistTip()
    init(playlist: Playlist) {
        self.playlist = playlist
        let playlistID = playlist.id
        _playlistEntries = Query(
            filter: #Predicate<PlaylistEntry> { entry in
                entry.playlist?.id == playlistID
            },
            sort: [SortDescriptor(\PlaylistEntry.order, order: .forward)]
        )
    }

    private var filteredEntries: [QueueEpisodeValue] {
        projection.filtered(using: filterState).entries
    }

    private var projectionRebuildKey: QueueProjectionRebuildKey {
        QueueProjectionRebuildKey(
            playlistID: playlist.id,
            entries: playlistEntries,
            downloadedFiles: fileManager.downloadedFiles,
            currentEpisodeURL: Player.shared.currentEpisodeURL,
            isPlaying: Player.shared.isPlaying,
            // Re-snapshot when filters change so in-progress/downloaded
            // filters see current values.
            filterState: filterState,
            generation: projectionGeneration
        )
    }

    private func rebuildProjection() {
        let displayedEpisodes = playlistEntries.compactMap(\.episode).filter { $0.url != nil }
        projection = QueueProjection(
            playlistID: playlist.id,
            playlistTitle: playlist.displayTitle,
            isSmartPlaylist: false,
            episodes: displayedEpisodes,
            downloadedFiles: fileManager.downloadedFiles
        )
        episodesByIdentity = Dictionary(
            displayedEpisodes.map { ($0.stableEpisodeIdentityKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let previousCount = hasBuiltProjection ? recordedEntryCount : nil
        hasBuiltProjection = true
        if previousCount != projection.count {
            recordedEntryCount = projection.count
            recordVisibleEntryCount()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            QueueFilterBar(projection: projection, filterState: $filterState)

            if hasBuiltProjection == false {
                Color.clear
            } else if projection.entries.isEmpty {
                PlaylistEmptyView(
                    title: playlist.displayTitle,
                    isSmartPlaylist: false,
                    isDefaultQueue: isDefaultQueue,
                    playlistID: playlist.id,
                    playlistSyncID: playlist.storeSplitSyncID
                )
            } else if filteredEntries.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Episodes", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Clear filters to see every episode in this playlist.")
                } actions: {
                    Button("Clear Filters") {
                        filterState.clear()
                    }
                }
            } else {
                List {
                    TipView(reorderTip, arrowEdge: .none)
                        .listRowSeparator(.hidden)

                    // Already restored entries stay playable while the rest
                    // of the synced queue is still on its way (#483).
                    if restoreStatus.readiness.isVisible {
                        PlaylistRestoreStatusView(
                            readiness: restoreStatus.readiness,
                            loginFeed: restoreStatus.facts.loginFeed,
                            isDefaultQueue: isDefaultQueue,
                            isRetrying: restoreStatus.isRetrying,
                            style: .row,
                            onRetry: retryRestore
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }

                    ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, value in
                        if let episode = episodesByIdentity[value.stableIdentityKey] {
                            ZStack {
                                EpisodeRowView(
                                    episode: episode,
                                    showsRemoveFromPlaylistAction: true,
                                    usesLivePlaybackProgress: index == 0,
                                    groupPosition: EpisodeRowGroupPosition(index: index, count: filteredEntries.count)
                                )
                                NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                                    EmptyView()
                                }
                                .opacity(0)
                            }
                            .buttonStyle(.plain)
                            .episodeRowSwipeActions(for: episode)
                            .accessibilityLabel("Open episode \(episode.title)")
                            .accessibilityHint("Opens this episode details screen")
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task {
                                        await removeEpisodeFromPlaylist(episode)
                                    }
                                } label: {
                                    Label("Remove from Playlist", systemImage: "minus.circle")
                                }

                                Button(role: .none) {
                                    Task {
                                        await archiveEpisode(episode)
                                    }
                                } label: {
                                    Label("Mark Archived", systemImage: "archivebox.fill")
                                }
                                .tint(.orange)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                        }
                    }
                    .onMove { indices, newOffset in
                        guard filterState.isFiltering == false,
                              let visibleFromIndex = indices.first,
                              filteredEntries.indices.contains(visibleFromIndex) else { return }
                        let fromIndex = filteredEntries[visibleFromIndex].orderIndex
                        let destinationIndex: Int
                        if newOffset >= filteredEntries.count {
                            destinationIndex = (filteredEntries.last?.orderIndex ?? fromIndex) + 1
                        } else {
                            destinationIndex = filteredEntries[newOffset].orderIndex
                        }
                        Task {
                            if let actor = try? PlaylistModelActor(modelContainer: modelContext.container, playlistID: playlist.id) {
                                try? await actor.moveEntry(from: fromIndex, to: destinationIndex)
                            }
                        }
                        ReorderPlaylistTip.hasUserReorderedBefore = true
                        reorderTip.invalidate(reason: .actionPerformed)
                    }
                    .moveDisabled(filterState.isFiltering)
                    // `initial: true` so the rule sees the current count, not just later changes;
                    // otherwise a playlist that never changes size never becomes eligible.
                    .onChange(of: filteredEntries.count, initial: true) { _, newCount in
                        ReorderPlaylistTip.playlistItemCount = newCount
                    }
                }
                .listStyle(.plain)
                .refreshesPlaylistRestoreStatus(
                    restoreStatus,
                    playlistSyncID: playlist.storeSplitSyncID,
                    isDefaultQueue: isDefaultQueue,
                    resolvedCount: projection.count
                )
                .toolbar {
                    if projection.count > 1 {
                        ToolbarItem(placement: .primaryAction) {
                            Button(action: smartShuffle) {
                                if isSmartShuffling {
                                    Label("Shuffling…", systemImage: "shuffle")
                                } else {
                                    Label("Smart Shuffle", systemImage: "shuffle")
                                }
                            }
                            .disabled(isSmartShuffling)
                            .accessibilityHint("Balances episodes across podcasts while keeping the playing episode in place")
                        }
                    }
                }
                .alert(
                    "Smart Shuffle",
                    isPresented: Binding(
                        get: { smartShuffleMessage != nil },
                        set: { if $0 == false { smartShuffleMessage = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) { smartShuffleMessage = nil }
                } message: {
                    Text(smartShuffleMessage ?? "")
                }
            }
        }
        .onChange(of: playlist.id) { _, _ in
            filterState.clear()
        }
        .onChange(of: projectionRebuildKey, initial: true) { _, _ in
            rebuildProjection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .splitRuntimeDidHydrate)) { _ in
            projectionGeneration &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .podcastFeedImportDidCommit)) { notification in
            guard let feed = notification.object as? URL,
                  projection.entries.contains(where: { $0.podcastFeedURL == feed }) else { return }
            projectionGeneration &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .episodeReferencesDidChange)) { notification in
            guard let url = notification.userInfo?[EpisodeReferenceNotificationKey.episodeURL] as? URL,
                  projection.entries.contains(where: { $0.episodeURL == url }) else { return }
            projectionGeneration &+= 1
        }
    }

    private var isDefaultQueue: Bool {
        playlist.title == Playlist.defaultQueueTitle
    }

    private func retryRestore() {
        let syncID = playlist.storeSplitSyncID
        let resolved = projection.count
        let isQueue = isDefaultQueue
        Task {
            await restoreStatus.retry(playlistSyncID: syncID, isDefaultQueue: isQueue, resolvedCount: resolved)
        }
    }

    private func recordVisibleEntryCount() {
        SupportDiagnosticsRecorder.shared.recordPlaylistVisibleCount(
            projection.count,
            isDefaultQueue: playlist.title == Playlist.defaultQueueTitle
        )
    }

    private func smartShuffle() {
        Task {
            isSmartShuffling = true
            defer { isSmartShuffling = false }
            do {
                let actor = try PlaylistModelActor(
                    modelContainer: modelContext.container,
                    playlistID: playlist.id
                )
                switch try await actor.smartShuffle() {
                case .reordered(let entryCount):
                    smartShuffleMessage = "Smart Shuffle reordered \(entryCount) episodes."
                case .alreadyBalanced:
                    smartShuffleMessage = "This playlist is already balanced across podcasts."
                case .unavailable:
                    smartShuffleMessage = "Add at least two episodes to use Smart Shuffle."
                }
            } catch {
                smartShuffleMessage = "Smart Shuffle couldn’t update this playlist: \(error.localizedDescription)"
            }
        }
    }

    private func archiveEpisode(_ episode: Episode) async {
        let episodeActor = EpisodeActor(modelContainer: modelContext.container)
        await episodeActor.archiveEpisode(episode.url)
    }

    private func removeEpisodeFromPlaylist(_ episode: Episode) async {
        guard let episodeURL = episode.url else { return }
        guard let playlistActor = try? PlaylistModelActor(
            modelContainer: modelContext.container,
            playlistID: playlist.id
        ) else {
            return
        }
        try? await playlistActor.remove(episodeURL: episodeURL)
    }
}
