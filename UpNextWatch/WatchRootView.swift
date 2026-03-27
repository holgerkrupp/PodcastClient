import SwiftUI

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
            return "Now Playing"
        case .upNext:
            return "Up Next"
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
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isShowingSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .foregroundStyle(.white)
                        }
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
                    }

                    WatchStorageStatusCard()

                    if store.playlist.isEmpty {
                        WatchEmptyState(
                            systemName: "text.line.first.and.arrowtriangle.forward",
                            title: "Up Next is empty",
                            detail: "Refresh from the phone to pull in the latest queue."
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

private struct WatchStorageStatusCard: View {
    @EnvironmentObject private var store: WatchSyncStore

    var body: some View {
        WatchPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Watch Storage")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    Text(store.usedStorageDescription)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                }

                WatchProgressBar(progress: storageProgress)

                Text("Downloads prefer Wi-Fi and stay within your watch storage limit.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    private var storageProgress: Double {
        guard store.storageSettings.maxStorageBytes > 0 else { return 0 }
        return Double(store.usedStorageBytes) / Double(store.storageSettings.maxStorageBytes)
    }
}

private struct WatchNowPlayingHero: View {
    @EnvironmentObject private var playback: WatchPlaybackController
    let episode: WatchSyncEpisode

    var body: some View {
        WatchPanel {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    WatchArtworkView(
                        url: playback.artworkURL(for: episode),
                        title: episode.title,
                        icon: "waveform"
                    )
                    .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Now Playing")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)

                        Text(episode.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let chapterTitle = playback.currentChapter?.title {
                            Text(chapterTitle)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                        }
                    }
                }

                WatchProgressBar(progress: playback.progress)

                HStack {
                    Text(watchPlaybackTime(playback.playPosition))
                    Spacer()
                    Text(watchPlaybackTime(playback.currentDuration ?? 0))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.72))
            }
        }
    }
}

private struct WatchPlaylistCard: View {
    @EnvironmentObject private var store: WatchSyncStore
    @EnvironmentObject private var playback: WatchPlaybackController

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
                        .foregroundStyle(.white.opacity(0.62))
                    }
                }

                HStack(spacing: 8) {
                    Button(playback.isActivelyPlaying(episode) ? "Pause" : "Play") {
                        playback.togglePlayback(for: episode)
                    }
                    .buttonStyle(WatchCapsuleButtonStyle(accent: .orange))

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
                        .buttonStyle(WatchCapsuleButtonStyle(accent: .teal))
                    }
                }

                if episode.phoneHasLocalFile && store.isDownloaded(episode) == false {
                    Text("The iPhone already has this file, so it should sync here when space opens up.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.58))
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
                title: episode.title,
                icon: store.isDownloaded(episode) ? "arrow.down.circle.fill" : "play.circle.fill"
            )
            .frame(width: 54, height: 54)

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
                            .foregroundStyle(.teal)
                    }
                }

                if let podcastTitle = episode.podcastTitle, podcastTitle.isEmpty == false {
                    Text(podcastTitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    WatchInfoPill(
                        text: store.isDownloaded(episode) ? "On Watch" : (episode.phoneHasLocalFile ? "Sync Ready" : "Stream"),
                        accent: store.isDownloaded(episode) ? .teal : .orange
                    )

                    if let chapter = currentChapter {
                        WatchInfoPill(text: chapter.title, accent: .white.opacity(0.22))
                    }
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

                            Text("Pull new episodes from the phone, then send the ones you want straight into Up Next.")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.65))

                            Button(store.isRefreshingInbox ? "Refreshing…" : "Refresh Inbox") {
                                store.refreshInbox()
                            }
                            .buttonStyle(WatchCapsuleButtonStyle(accent: .teal))
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
                        title: episode.title,
                        icon: "tray.and.arrow.down.fill"
                    )
                    .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(episode.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let podcastTitle = episode.podcastTitle, podcastTitle.isEmpty == false {
                            Text(podcastTitle)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                        }
                    }
                }

                Button(episode.resolvedAudioURL == nil ? "Add to Up Next" : "Queue + Download") {
                    store.queueEpisode(episode, downloadAfterQueue: episode.resolvedAudioURL != nil)
                }
                .buttonStyle(WatchCapsuleButtonStyle(accent: .orange))
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

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)

                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)

                Button("Sync Now", action: action)
                    .buttonStyle(WatchCapsuleButtonStyle(accent: .teal))
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
