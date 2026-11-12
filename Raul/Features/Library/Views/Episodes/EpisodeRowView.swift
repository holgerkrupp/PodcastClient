//
//  EpisodeRowView.swift
//  Raul
//
//  Created by Holger Krupp on 12.04.25.
//
import SwiftUI
import ESADesignKit
import Combine

struct EpisodeRowView: View {
    @Environment(\.deviceUIStyle) var style
    @Environment(DownloadedFilesManager.self) var fileManager
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.esaVisualStyle) private var visualStyle
    @Environment(\.esaArtworkBlurLevel) private var artworkBlurLevel
    @AppStorage("SimplifiedRows") private var simplifiedRowsEnabled = false

    @Bindable var episode: Episode
    let showsRemoveFromInboxAction: Bool
    let showsRemoveFromPlaylistAction: Bool
    let usesLivePlaybackProgress: Bool
    @State private var referenceAvailability = EpisodeReferenceAvailability()
    @ScaledMetric(relativeTo: .body) private var standardRowHeight: CGFloat = 210
    @ScaledMetric(relativeTo: .body) private var artworkSize: CGFloat = 120
    @ScaledMetric(relativeTo: .body) private var controlsHeight: CGFloat = 50
    @ScaledMetric(relativeTo: .title3) private var nowPlayingBadgeWidth: CGFloat = 300
    @ScaledMetric(relativeTo: .title3) private var nowPlayingBadgeHeight: CGFloat = 120

    private var rowHeight: CGFloat { simplifiedRowsEnabled ? 112 : standardRowHeight }

    init(
        episode: Episode,
        showsRemoveFromInboxAction: Bool = false,
        showsRemoveFromPlaylistAction: Bool = false,
        usesLivePlaybackProgress: Bool = false
    ) {
        self._episode = Bindable(wrappedValue: episode)
        self._referenceAvailability = State(
            initialValue: EpisodeReferenceAvailability.seeded(from: episode)
        )
        self.showsRemoveFromInboxAction = showsRemoveFromInboxAction
        self.showsRemoveFromPlaylistAction = showsRemoveFromPlaylistAction
        self.usesLivePlaybackProgress = usesLivePlaybackProgress
    }
  
    
    var body: some View {
        let downloadedFiles = fileManager.downloadedFiles
        let podcastTitle = episode.displayPodcastTitle ?? ""
        let publishText = episode.publishDate?.formatted(.relative(presentation: .named)) ?? ""
        let duration = episode.duration ?? 0.0
        let remainingTime = episode.displayRemainingTime
        let showRemaining = remainingTime != nil && remainingTime != duration && (remainingTime ?? 0) > 0
        let timeText = Duration.seconds(showRemaining ? (remainingTime ?? 0) : duration).formatted(.units(width: .narrow))
        let timeDisplay = showRemaining ? timeText + " remaining" : timeText
        let completionDate = episode.metaData?.completionDate
        let isDownloaded = isDownloaded(downloadedFiles: downloadedFiles)
            || episode.metaData?.calculatedIsAvailableLocally == true
        let hasChapters = referenceAvailability.hasChapters
        let hasTranscript = referenceAvailability.hasTranscript
        let hasBookmarks = referenceAvailability.hasBookmarks
        let episodeTypeBadgeText = badgeText(for: episode.type)

        let rowContent = Group {
            if simplifiedRowsEnabled {
                simplifiedRow(
                    podcastTitle: podcastTitle,
                    publishText: publishText,
                    timeDisplay: timeDisplay,
                    completionDate: completionDate,
                    isDownloaded: isDownloaded,
                    episodeTypeBadgeText: episodeTypeBadgeText,
                    hasBookmarks: hasBookmarks,
                    hasTranscript: hasTranscript,
                    hasChapters: hasChapters
                )
            } else {
        VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        CoverImageView(episode: episode, maxPixelSize: 512)
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

                        if hasBookmarks {
                            Image(systemName: "bookmark.fill")
                                .font(.title2)
                                .foregroundStyle(.accent)
                                .padding(8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                .accessibilityLabel("Has bookmarks")
                        }
                    }
                    .frame(width: artworkSize, height: artworkSize)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            Text(podcastTitle)
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

                        Text(timeDisplay)
                            .font(.caption)
                            .esaForeground(.secondary)

                        HStack(spacing: 10) {
                            if completionDate != nil {
                                Image("custom.play.circle.badge.checkmark")
                                    .accessibilityLabel("Played")
                            } else if isDownloaded {
                                Image(systemName: style.sfSymbolName)
                                    .accessibilityLabel("Downloaded")
                            } else {
                                Image(systemName: "cloud")
                                    .accessibilityLabel("Not downloaded")
                            }

                            if hasChapters {
                                Image(systemName: "list.bullet")
                                    .accessibilityLabel("Has chapters")
                            }
                            if hasTranscript {
                                Image(systemName: "quote.bubble")
                                    .accessibilityLabel("Has transcript")
                            }

                            Spacer()

                            DownloadControllView(episode: episode, showDelete: false)
                                .symbolRenderingMode(.hierarchical)
                                .esaForeground(.control)
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, minHeight: artworkSize, alignment: .topLeading)
                }
                if Player.shared.currentEpisodeURL != episode.url {
                    EpisodeControlView(
                        episode: episode,
                        showsRemoveFromInboxAction: showsRemoveFromInboxAction,
                        showsRemoveFromPlaylistAction: showsRemoveFromPlaylistAction
                    )
                        .frame(minHeight: controlsHeight)
                }
            }
        .padding(8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .background {
            if visualStyle == .artwork && colorSchemeContrast == .standard {
                Rectangle().fill(artworkBlurLevel.rowMaterial)
            }
        }
        .background {
            if visualStyle == .artwork && colorSchemeContrast == .standard {
            BlurredCoverImageView(
                imageURL: episode.imageURL ?? episode.podcast?.imageURL,
                radius: artworkBlurLevel.rowBlurRadius,
                maxPixelSize: 512
            )
            .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)
            .clipped()
            .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottomLeading) {
            EpisodeRowPlaybackProgressView(
                episode: episode,
                usesLivePlaybackProgress: usesLivePlaybackProgress
            )
        }
            .overlay{


                if episode.url == Player.shared.currentEpisode?.url {
                        Group {
                            if Player.shared.isPlaying {
                                Label("Now Playing", systemImage: "waveform")
                                    .symbolEffect(
                                        .bounce.up.byLayer,
                                        options: reduceMotion ? .nonRepeating : .repeat(.continuous)
                                    )
                                    .esaForeground(.primary)
                                    .font(.title.bold())
                            } else {
                                Label("Now Playing", systemImage: "waveform.low")
                                    .esaForeground(.primary)
                                    .font(.title.bold())
                            }
                        }
                        .frame(width: nowPlayingBadgeWidth, height: nowPlayingBadgeHeight)
              
                        
                    
             .background{
                 RoundedRectangle(cornerRadius:  20.0)
                     .fill(Color.black.opacity(differentiateWithoutColor ? 0.5 : 0.3))
             }
          
             
             .glassEffect(.clear, in: RoundedRectangle(cornerRadius:  20.0))
             .frame(maxWidth: nowPlayingBadgeWidth, maxHeight: nowPlayingBadgeHeight, alignment: .center)
            }
                
            }
            .task(id: episode.url) {
                await Task.yield()
                guard Task.isCancelled == false else { return }
                refreshReferenceAvailability()
            }
            .onChange(of: fileManager.downloadedFiles) { _, _ in
                refreshReferenceAvailability()
            }
            .onReceive(NotificationCenter.default.publisher(for: .episodeReferencesDidChange).receive(on: DispatchQueue.main)) { notification in
                handleEpisodeReferencesDidChange(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .episodeDownloadFinished).receive(on: DispatchQueue.main)) { notification in
                handleEpisodeDownloadFinished(notification)
            }

        if visualStyle == .artwork {
            rowContent
        } else {
            rowContent.ESA_RowView(
                image: episode.imageURL ?? episode.podcast?.imageURL,
                minHeight: rowHeight
            )
        }

    }

    @ViewBuilder
    private func simplifiedRow(
        podcastTitle: String,
        publishText: String,
        timeDisplay: String,
        completionDate: Date?,
        isDownloaded: Bool,
        episodeTypeBadgeText: String?,
        hasBookmarks: Bool,
        hasTranscript: Bool,
        hasChapters: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .topLeading) {
                CoverImageView(episode: episode, maxPixelSize: 384)
                    .frame(width: 84, height: 84)
                    .accessibilityHidden(true)
                if let episodeTypeBadgeText {
                    Text(episodeTypeBadgeText)
                        .font(.caption2.weight(.semibold))
                        .padding(5)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                if hasBookmarks {
                    Image(systemName: "bookmark.fill")
                        .font(.caption)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .accessibilityLabel("Has bookmarks")
                }
            }
            .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: 4) {
                Text(podcastTitle)
                    .font(.caption)
                    .esaForeground(.secondary)
                    .lineLimit(1)
                Text(episode.title)
                    .font(.headline)
                    .lineLimit(3)
                    .esaForeground(.primary)
                HStack(spacing: 8) {
                    Text(timeDisplay)
                    if completionDate != nil {
                        Label("Played", systemImage: "checkmark.circle")
                    } else if isDownloaded {
                        Label("Downloaded", systemImage: "arrow.down.circle")
                    }
                    if hasChapters { Image(systemName: "list.bullet").accessibilityLabel("Has chapters") }
                    if hasTranscript { Image(systemName: "quote.bubble").accessibilityLabel("Has transcript") }
                    Spacer(minLength: 0)
                    Text(publishText).lineLimit(1)
                }
                .font(.caption2)
                .esaForeground(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .background {
            if visualStyle == .artwork && colorSchemeContrast == .standard {
                Rectangle().fill(artworkBlurLevel.rowMaterial)
            }
        }
        .overlay(alignment: .bottomLeading) {
            EpisodeRowPlaybackProgressView(episode: episode, usesLivePlaybackProgress: usesLivePlaybackProgress)
        }
        .overlay(alignment: .topTrailing) {
            if episode.url == Player.shared.currentEpisode?.url {
                Label(Player.shared.isPlaying ? "Now Playing" : "Paused", systemImage: Player.shared.isPlaying ? "waveform" : "waveform.low")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
        }
    }

    private struct EpisodeRowPlaybackProgressView: View {
        @Bindable var episode: Episode
        let usesLivePlaybackProgress: Bool

        private var progress: Double {
            let storedProgress = episode.displayProgress
            guard usesLivePlaybackProgress,
                  Player.shared.currentEpisodeURL == episode.url else {
                return clamped(storedProgress)
            }

            return clamped(Player.shared.progress)
        }

        var body: some View {
            Rectangle()
                .fill(Color.accent)
                .scaleEffect(x: progress, y: 1, anchor: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: 4)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityHidden(true)
        }

        private func clamped(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            return min(max(value, 0), 1)
        }
    }

    private func badgeText(for type: EpisodeType?) -> String? {
        switch type {
        case .trailer:
            return "Trailer"
        case .bonus:
            return "Bonus"
        case .full, .unknown, nil:
            return nil
        }
    }

    private func isDownloaded(downloadedFiles: Set<URL>) -> Bool {
        guard episode.source != .sideLoaded else { return true }
        guard let localFile = episode.localFile?.standardizedFileURL else { return false }
        return downloadedFiles.contains(localFile)
    }

    private func refreshReferenceAvailability(invalidate: Bool = false) {
        guard let episodeURL = episode.url else {
            updateReferenceAvailability(EpisodeReferenceAvailability.seeded(from: episode))
            return
        }

        if invalidate {
            EpisodeReferenceAvailabilityCache.shared.invalidate(episodeURL)
        } else if let cachedAvailability = EpisodeReferenceAvailabilityCache.shared.availability(for: episodeURL) {
            updateReferenceAvailability(cachedAvailability)
            return
        }

        let availability = EpisodeReferenceAvailability.seeded(from: episode)
        EpisodeReferenceAvailabilityCache.shared.store(availability, for: episodeURL)
        updateReferenceAvailability(availability)
    }

    private func updateReferenceAvailability(_ availability: EpisodeReferenceAvailability) {
        if referenceAvailability != availability {
            referenceAvailability = availability
        }
    }

    private func handleEpisodeReferencesDidChange(_ notification: Notification) {
        guard notificationMatchesEpisode(notification, urlKey: EpisodeReferenceNotificationKey.episodeURL) else { return }
        fileManager.refreshDownloadedFiles()
        refreshReferenceAvailability(invalidate: true)
    }

    private func handleEpisodeDownloadFinished(_ notification: Notification) {
        guard notificationMatchesEpisode(notification, urlKey: EpisodeDownloadNotificationKey.episodeURL) else { return }
        fileManager.refreshDownloadedFiles()
        refreshReferenceAvailability()
    }

    private func notificationMatchesEpisode(_ notification: Notification, urlKey: String) -> Bool {
        guard let url = notificationURL(from: notification.userInfo?[urlKey]) else {
            return true
        }
        return episode.url == url
    }

    private func notificationURL(from value: Any?) -> URL? {
        if let url = value as? URL {
            return url
        }
        if let url = value as? NSURL {
            return url as URL
        }
        if let string = value as? String {
            return URL(string: string)
        }
        return nil
    }
    

}

private struct EpisodeRowSwipeActionModifier: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.episodeControlPlaylists) private var playlists
    @AppStorage(PlaylistPreferenceKeys.selectedPlaylistID) private var selectedPlaylistID = ""
    @State private var statusMessage: String?

    let episode: Episode

    private var resolvedPlaylist: EpisodeControlPlaylist? {
        if let id = UUID(uuidString: selectedPlaylistID),
           let selected = playlists.first(where: { $0.id == id && !$0.isDefaultQueue }) {
            return selected
        }
        return playlists.first(where: \.isDefaultQueue)
            ?? playlists.first(where: { !$0.isDefaultQueue })
    }

    private var actionTitle: String {
        guard let playlist = resolvedPlaylist, playlist.isDefaultQueue == false else {
            return NSLocalizedString("Add to Up Next", comment: "Adds an episode to the default Up Next queue")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("Add to %@", comment: "Adds an episode to a named playlist"),
            playlist.title
        )
    }

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    Task { await addToSelectedPlaylist() }
                } label: {
                    Label(actionTitle, systemImage: "text.line.last.and.arrowtriangle.forward")
                }
                .tint(.accentColor)
            }
            .contextMenu {
                Button(actionTitle, systemImage: "text.line.last.and.arrowtriangle.forward") {
                    Task { await addToSelectedPlaylist() }
                }
            }
            .accessibilityAction(named: Text(actionTitle)) {
                Task { await addToSelectedPlaylist() }
            }
            .overlay(alignment: .topTrailing) {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
    }

    @MainActor
    private func addToSelectedPlaylist() async {
        guard let episodeURL = episode.url else {
            showStatus("Episode is unavailable")
            return
        }

        do {
            let playlistID = try Playlist.resolvedSelectedManualPlaylistID(in: modelContext)
            let actor = try PlaylistModelActor(modelContainer: modelContext.container, playlistID: playlistID)
            if try await actor.appendIfAbsent(episodeURL: episodeURL) == false {
                let title = playlists.first(where: { $0.id == playlistID })?.title ?? "Up Next"
                showStatus(String.localizedStringWithFormat(
                    NSLocalizedString("Already in %@", comment: "Indicates an episode is already in a playlist"),
                    title
                ))
                return
            }
            showStatus(String.localizedStringWithFormat(
                NSLocalizedString("Added the episode to %@.", comment: "Confirms adding an episode to a playlist"),
                playlists.first(where: { $0.id == playlistID })?.title ?? "Up Next"
            ))
        } catch {
            AppDiagnostics.log("[Playlist] Episode swipe addition failed (\(String(describing: type(of: error))))")
            showStatus(NSLocalizedString("Couldn’t Add Episode", comment: "Reports that an episode could not be added to a playlist"))
        }
    }

    @MainActor
    private func showStatus(_ message: String) {
        statusMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            statusMessage = nil
        }
    }
}

extension View {
    func episodeRowSwipeActions(for episode: Episode) -> some View {
        modifier(EpisodeRowSwipeActionModifier(episode: episode))
    }
}

private struct EpisodeReferenceAvailability: Equatable {
    var hasChapters = false
    var hasTranscript = false
    var hasBookmarks = false

    static func seeded(from episode: Episode) -> EpisodeReferenceAvailability {
        EpisodeReferenceAvailability(
            hasChapters: episode.chapters?.isEmpty == false,
            hasTranscript: episode.hasLoadedTranscript
                || episode.externalFiles.contains(where: { $0.category == .transcript }),
            hasBookmarks: episode.bookmarks?.isEmpty == false
        )
    }
}

@MainActor
private final class EpisodeReferenceAvailabilityCache {
    static let shared = EpisodeReferenceAvailabilityCache()

    private var cache: [URL: EpisodeReferenceAvailability] = [:]

    func availability(for url: URL) -> EpisodeReferenceAvailability? {
        cache[url]
    }

    func store(_ availability: EpisodeReferenceAvailability, for url: URL) {
        cache[url] = availability
    }

    func invalidate(_ url: URL?) {
        if let url {
            cache[url] = nil
        } else {
            cache.removeAll()
        }
    }
}

#Preview {
    let podcast: Podcast = {
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        podcast.title = "Sample Podcast"
        podcast.author = "Sample Author"
        podcast.desc = "A fun show about testing previews."
        return podcast
    }()

    let episode: Episode = {
        let episode = Episode(
            title: "Sample Episode Title",
            publishDate: Date(),
            url: URL(string: "https://example.com/episode.mp3")!,
            podcast: podcast,
            duration: 3600,
            author: "Episode Author"
        )
        episode.desc = "A very interesting episode about previews."
        episode.metaData?.playPosition = 900 // Simulate 15 mins listened
        episode.metaData?.maxPlayposition = 1200 // Simulate max progress
        episode.metaData?.lastPlayed = Date()
        return episode
    }()

    // Inject a dummy DownloadedFilesManager for preview
    let tempFolder = FileManager.default.temporaryDirectory
    let previewFilesManager = DownloadedFilesManager(folder: tempFolder)

    EpisodeRowView(episode: episode)
        .environment(previewFilesManager)
}
