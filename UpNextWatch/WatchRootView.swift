import SwiftUI
import DeviceInfo

struct WatchRootView: View {
    private enum WatchPage: Hashable {
        case nowPlaying
        case upNext
        case inbox
    }

    @EnvironmentObject private var store: WatchSyncStore
    @EnvironmentObject private var playback: WatchPlaybackController
    @State private var isShowingSettings = false
    @State private var selectedPage: WatchPage = .upNext

    private var alertMessage: String? {
        playback.errorMessage ?? store.errorMessage
    }

    private var pageTitle: String {
        switch selectedPage {
        case .nowPlaying:
            return store.isRemoteControlEnabled ? "iPhone" : "Now Playing"
        case .upNext:
            return store.selectedPlaylistTitle
        case .inbox:
            return "Inbox"
        }
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedPage) {
                if let currentEpisode = playback.currentEpisode {
                    WatchPlayerView(episodeID: currentEpisode.id, presentationStyle: .page)
                        .tag(WatchPage.nowPlaying)
                }

                WatchPlaylistPage {
                    selectedPage = .nowPlaying
                }
                    .tag(WatchPage.upNext)

                WatchInboxPage()
                    .tag(WatchPage.inbox)
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .navigationTitle(pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if selectedPage == .upNext {
                    ToolbarItem(placement: .topBarLeading) {
                        WatchPlaylistMenu()
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isShowingSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel("Settings")
                        .accessibilityHint("Open watch storage and download settings")
                    }
                }

                if selectedPage == .nowPlaying, store.isRemoteControlEnabled {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            selectedPage = .upNext
                        } label: {
                            Label("Playlist", systemImage: "list.bullet")
                        }
                        .foregroundStyle(.white)
                        .accessibilityHint("Returns to the watch playlist")
                    }
                }

                if selectedPage == .inbox {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            store.refreshInbox()
                        } label: {
                            if store.isRefreshingInbox {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundStyle(.white)
                            }
                        }
                        .disabled(store.isRefreshingInbox)
                        .accessibilityLabel(store.isRefreshingInbox ? "Refreshing inbox" : "Refresh inbox")
                        .accessibilityHint("Loads the latest inbox episodes from your phone")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                WatchStorageSettingsView()
                    .environmentObject(store)
            }
        }
        .onChange(of: playback.currentEpisode?.id) { _, newEpisodeID in
            if newEpisodeID == nil, selectedPage == .nowPlaying {
                selectedPage = .upNext
            }
        }
        .alert(
            "Up Next Watch",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { isPresented in
                    if isPresented == false {
                        store.errorMessage = nil
                        playback.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                store.errorMessage = nil
                playback.errorMessage = nil
            }
        } message: {
            Text(alertMessage ?? "")
        }
    }
}

private struct WatchPlaylistMenu: View {
    @EnvironmentObject private var store: WatchSyncStore
    @State private var isShowingPicker = false

    var body: some View {
        Button {
            isShowingPicker = true
        } label: {
            Image(systemName: "list.bullet")
                .foregroundStyle(.white)
        }
        .disabled(store.playlists.isEmpty)
        .confirmationDialog("Playlist", isPresented: $isShowingPicker, titleVisibility: .visible) {
            ForEach(store.playlists) { playlist in
                Button(playlist.isSelected ? "\(playlist.title) (Selected)" : playlist.title) {
                    store.selectPlaylist(playlist)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityLabel("Playlist")
        .accessibilityValue(store.selectedPlaylistTitle)
        .accessibilityHint("Choose which playlist appears on the watch")
    }
}

private struct WatchPlaylistPage: View {
    @EnvironmentObject private var store: WatchSyncStore
    @EnvironmentObject private var playback: WatchPlaybackController
    let showNowPlaying: () -> Void

    var body: some View {
        ZStack {
            WatchAppBackground()

            ScrollView {
                VStack(spacing: 12) {
                    if let currentEpisode = playback.currentEpisode {
                        Button(action: showNowPlaying) {
                            WatchNowPlayingHero(episode: currentEpisode)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Now playing \(currentEpisode.title)")
                        .accessibilityHint("Opens the full now playing screen")
                    }

                    if store.isRemoteControlEnabled {
                        WatchRemoteStatusCard()
                    } else {
                        WatchStorageStatusCard()
                    }

                    if store.playlist.isEmpty {
                        WatchEmptyState(
                            systemName: "text.line.first.and.arrowtriangle.forward",
                            title: "\(store.selectedPlaylistTitle) is empty",
                            detail: "Refresh from the phone to pull in the latest playlist."
                        ) {
                            store.requestSnapshot()
                        }
                    } else {
                        ForEach(store.playlist) { episode in
                            WatchPlaylistCard(episode: episode, showNowPlaying: showNowPlaying)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct WatchRemoteStatusCard: View {
    @EnvironmentObject private var store: WatchSyncStore

    var body: some View {
        WatchPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("iPhone Remote")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.84))
                    Spacer()
                    Text(statusText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)
                }

                if store.isPhoneReachable == false && store.hasRecentPhonePlaybackState == false {
                    Text("Open the iPhone app once so the watch can control playback.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
        }
    }

    private var statusText: String {
        if store.isPhoneReachable { return "Live" }
        if store.hasRecentPhonePlaybackState { return "Snapshot" }
        return "Unavailable"
    }

    private var statusColor: Color {
        if store.isPhoneReachable { return .upNextAccent }
        if store.hasRecentPhonePlaybackState { return .orange }
        return .red
    }
}

private struct WatchStorageStatusCard: View {
    @EnvironmentObject private var store: WatchSyncStore

    var body: some View {
        WatchPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Watch Storage")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.84))
                    Spacer()
                    Text(store.usedStorageDescription)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                }

                WatchProgressBar(progress: storageProgress)
/*
                Text("Downloads prefer Wi-Fi and stay within your watch storage limit.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.78))
 */
            }
        }
    }

    private var storageProgress: Double {
        guard store.storageSettings.maxStorageBytes > 0 else { return 0 }
        return Double(store.usedStorageBytes) / Double(store.storageSettings.maxStorageBytes)
    }
}

private struct WatchRemotePlaylistControls: View {
    @EnvironmentObject private var store: WatchSyncStore
    @State private var isShowingActions = false
    let episode: WatchSyncEpisode

    private var episodeIndex: Int? {
        store.playlist.firstIndex(where: { $0.episodeURL == episode.episodeURL })
    }

    private var canMoveUp: Bool {
        (episodeIndex ?? 0) > 0
    }

    private var canMoveDown: Bool {
        guard let episodeIndex else { return false }
        return episodeIndex < store.playlist.count - 1
    }

    var body: some View {
        Button("Manage") {
            isShowingActions = true
        }
        .buttonStyle(WatchCapsuleButtonStyle(accent: .upNextAccent))
        .disabled(store.isRemoteControlAvailable == false)
        .confirmationDialog("Manage Episode", isPresented: $isShowingActions, titleVisibility: .visible) {
            if canMoveUp {
                Button("Move Up") {
                    store.remoteMovePlaylistEpisode(episode, offset: -1)
                }
            }

            if canMoveDown {
                Button("Move Down") {
                    store.remoteMovePlaylistEpisode(episode, offset: 1)
                }
            }

            Button("Remove", role: .destructive) {
                store.remoteRemoveFromPlaylist(episode)
            }

            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct WatchNowPlayingHero: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var playback: WatchPlaybackController
    let episode: WatchSyncEpisode

    var body: some View {
        WatchPanel {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    WatchArtworkView(
                        url: playback.artworkURL(for: episode),
                        title: episode.title
                    )
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Now Playing")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.upNextAccent)

                        Text(episode.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                            .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let chapterTitle = playback.currentChapter?.title {
                            Text(chapterTitle)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.78))
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                        }
                    }
                }

                WatchProgressBar(progress: playback.progress)

                HStack {
                    Text(watchPlaybackTime(playback.displayedPlayPosition))
                    Spacer()
                    Text(watchPlaybackTime(playback.currentDuration ?? 0))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.84))
            }
        }
    }
}

private struct WatchPlaylistCard: View {
    @EnvironmentObject private var store: WatchSyncStore
    @EnvironmentObject private var playback: WatchPlaybackController
    @Environment(\.deviceUIStyle) var style

    let episode: WatchSyncEpisode
    let showNowPlaying: () -> Void

    var body: some View {
        WatchPanel {
            VStack(alignment: .leading, spacing: 10) {
                if playback.isCurrentEpisode(episode) {
                    Button(action: showNowPlaying) {
                        episodeHeader
                            
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Now playing \(episode.title)")
                    .accessibilityHint("Opens full playback controls")
                } else {
                    NavigationLink {
                        WatchPlayerView(episodeID: episode.id)
                    } label: {
                        episodeHeader
                    }
                    .buttonStyle(.plain)
                }

                if let progress = playback.displayedProgress(for: episode) {
                    VStack(spacing: 6) {
                        WatchProgressBar(progress: progress)
                        HStack {
                            Text(watchPlaybackTime(playback.displayedPosition(for: episode)))
                            Spacer()
                            Text(watchPlaybackTime(episode.duration ?? 0))
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.78))
                    }
                }

                if store.isRemoteControlEnabled == false,
                   let syncProgress = store.syncProgress(for: episode),
                   store.isDownloaded(episode) == false {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Syncing")
                            Spacer()
                            Text(syncProgress, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.upNextAccent)

                        WatchProgressBar(progress: syncProgress)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Syncing \(episode.title)")
                    .accessibilityValue(Text(syncProgress.formatted(.percent.precision(.fractionLength(0)))))
                }

                HStack(spacing: 8) {
                    Button(playback.isActivelyPlaying(episode) ? "Pause" : "Play") {
                        playback.togglePlayback(for: episode)
                    }
                    .buttonStyle(WatchCapsuleButtonStyle(accent: .upNextAccent))
                    .disabled(store.isRemoteControlEnabled && store.isRemoteControlAvailable == false)

                    if store.isRemoteControlEnabled {
                        WatchRemotePlaylistControls(episode: episode)
                    } else {
                        if store.isDownloaded(episode) {
                            Button("Remove") {
                                store.removeDownload(episode)
                            }
                            .buttonStyle(WatchCapsuleButtonStyle(accent: .red))
                        } else {
                            Button(store.isDownloading(episode) ? "Loading" : "Download") {
                                store.downloadEpisode(episode)
                            }
                            .disabled(store.isDownloading(episode))
                            .buttonStyle(WatchCapsuleButtonStyle(accent: .upNextAccent))
                        }
                    }
                }

                if store.isRemoteControlEnabled == false,
                   episode.phoneHasLocalFile,
                   store.isDownloaded(episode) == false {
                    Text("Wait for episode to sync")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.74))
                }
            }
        }
    }

    private var currentChapter: WatchSyncChapter? {
        if playback.isCurrentEpisode(episode) {
            return playback.currentChapter
        }

        return episode.chapter(at: episode.playPosition)
    }

    private var episodeHeader: some View {
        HStack(spacing: 10) {
            WatchArtworkView(
                url: playback.artworkURL(for: episode),
                title: episode.title
            )
            .frame(width: 54, height: 54)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 6) {
                    Text(episode.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if playback.isActivelyPlaying(episode) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.upNextAccent)
                            .accessibilityHidden(true)
                    }
                }

                if let podcastTitle = episode.podcastTitle, podcastTitle.isEmpty == false {
                    Text(podcastTitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    
                    if store.isRemoteControlEnabled {
                        Image(systemName: "iphone")
                            .accessibilityLabel("iPhone remote")
                    } else if store.isDownloaded(episode) {
                        Image(systemName: style.sfSymbolName)
                            .accessibilityLabel("Downloaded")
                    } else {
                        Image(systemName: "cloud")
                            .accessibilityLabel("Not downloaded")
                    }
                    /*
                    WatchInfoPill(
                        text: store.isDownloaded(episode) ? "On Watch" : (episode.phoneHasLocalFile ? "Sync Ready" : "Stream"),
                        accent: store.isDownloaded(episode) ? .teal : .orange
                    )

                    if let chapter = currentChapter {
                        WatchInfoPill(text: chapter.title, accent: .white.opacity(0.22))
                    }
 */
                }
            }
        }
    }
}

private struct WatchInboxPage: View {
    @EnvironmentObject private var store: WatchSyncStore

    var body: some View {
        ZStack {
            WatchAppBackground()

            ScrollView {
                VStack(spacing: 12) {
                    WatchPanel {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Inbox")
                                .font(.headline)
                                .foregroundStyle(.white)

                            Text("Pull new episodes from the phone, then send the ones you want into \(store.selectedPlaylistTitle).")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.78))

                            Button(store.isRefreshingInbox ? "Refreshing…" : "Refresh Inbox") {
                                store.refreshInbox()
                            }
                            .buttonStyle(WatchCapsuleButtonStyle(accent: .upNextAccent))
                            .disabled(store.isRefreshingInbox)
                        }
                    }

                    if store.inbox.isEmpty {
                        WatchEmptyState(
                            systemName: "tray",
                            title: "Inbox is empty",
                            detail: "Refresh from the watch whenever you want the latest feed updates."
                        ) {
                            store.refreshInbox()
                        }
                    } else {
                        ForEach(store.inbox) { episode in
                            WatchInboxCard(episode: episode)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct WatchInboxCard: View {
    @EnvironmentObject private var store: WatchSyncStore
    let episode: WatchSyncEpisode

    var body: some View {
        WatchPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    WatchArtworkView(
                        url: episode.resolvedImageURL,
                        title: episode.title
                    )
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(episode.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let podcastTitle = episode.podcastTitle, podcastTitle.isEmpty == false {
                            Text(podcastTitle)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.78))
                                .lineLimit(1)
                        }
                    }
                }

                Button {
                    store.queueEpisode(episode, downloadAfterQueue: episode.resolvedAudioURL != nil)
                } label: {
                    Text(episode.resolvedAudioURL == nil ? "Add to \(store.selectedPlaylistTitle)" : "Queue + Download")
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .buttonStyle(WatchCapsuleButtonStyle(accent: .upNextAccent))
                .accessibilityHint("Adds this episode to \(store.selectedPlaylistTitle) and downloads it when available")
            }
        }
    }
}

private struct WatchEmptyState: View {
    let systemName: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        WatchPanel {
            VStack(spacing: 10) {
                Image(systemName: systemName)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.82))
                    .accessibilityHidden(true)

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)

                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.center)

                Button("Sync Now", action: action)
                    .buttonStyle(WatchCapsuleButtonStyle(accent: .upNextAccent))
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct WatchInfoPill: View {
    let text: String
    let accent: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .scaledToFit()
            .minimumScaleFactor(0.01)
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(accent)
            )
            
    }
    
    
}

extension DeviceUIStyle {
    var sfSymbolName: String {
        switch self {
        case .iphoneHomeButton: return "iphone.gen1"
        case .iphoneNotch: return "iphone.gen2"
        case .iphoneDynamicIsland: return "iphone.gen3"
        case .ipadHomeButton: return "ipad.gen1"
        case .ipadNoHomeButton: return "ipad.gen2"
        case .appleWatch: return "applewatch"
        case .visionPro: return "visionpro"
        case .macLaptop: return "macbook"
        case .macMini: return "macmini"
        case .macPro: return "macpro.gen3"
        case .macDesktop: return "desktopcomputer"
        @unknown default: return "questionmark.square.dashed"
        }
    }
}

#if DEBUG
#Preview("Watch Root") {
    let store = WatchSyncStore.preview()
    let playback = WatchPlaybackController()
    playback.attach(store: store)

    return WatchRootView()
        .environmentObject(store)
        .environmentObject(playback)
}

#Preview("Watch Root Empty") {
    let store = WatchSyncStore.preview(
        snapshot: WatchSyncSnapshot(
            generatedAt: .now,
            playlist: [],
            inbox: [],
            playlists: WatchPreviewData.playlists
        ),
        downloadedEpisodes: [],
        usedStorageBytes: 0
    )
    let playback = WatchPlaybackController()
    playback.attach(store: store)

    return WatchRootView()
        .environmentObject(store)
        .environmentObject(playback)
}
#endif
