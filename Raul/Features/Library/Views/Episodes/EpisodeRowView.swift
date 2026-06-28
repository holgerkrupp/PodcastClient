//
//  EpisodeRowView.swift
//  Raul
//
//  Created by Holger Krupp on 12.04.25.
//
import SwiftUI
import SwiftData
import Combine

struct EpisodeRowView: View {
    @Environment(\.deviceUIStyle) var style
    @Environment(DownloadedFilesManager.self) var fileManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    @Bindable var episode: Episode
    @State private var referenceAvailability = EpisodeReferenceAvailability()
    @State private var referenceRefreshID = UUID()
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 210
    @ScaledMetric(relativeTo: .body) private var artworkSize: CGFloat = 120
    @ScaledMetric(relativeTo: .body) private var controlsHeight: CGFloat = 50
    @ScaledMetric(relativeTo: .title3) private var nowPlayingBadgeWidth: CGFloat = 300
    @ScaledMetric(relativeTo: .title3) private var nowPlayingBadgeHeight: CGFloat = 120

    init(episode: Episode) {
        self._episode = Bindable(wrappedValue: episode)
    }
  
    
    var body: some View {
        let _ = episode.refresh
        let _ = referenceRefreshID
        let downloadedFiles = fileManager.downloadedFiles
        let podcastTitle = episode.displayPodcastTitle ?? ""
        let publishText = episode.publishDate?.formatted(.relative(presentation: .named)) ?? ""
        let duration = episode.duration ?? 0.0
        let remainingTime = episode.displayRemainingTime
        let showRemaining = remainingTime != nil && remainingTime != duration && (remainingTime ?? 0) > 0
        let timeText = Duration.seconds(showRemaining ? (remainingTime ?? 0) : duration).formatted(.units(width: .narrow))
        let timeDisplay = showRemaining ? timeText + " remaining" : timeText
        let completionDate = episode.metaData?.completionDate
        let isDownloaded = referenceAvailability.isDownloaded || isDownloaded(downloadedFiles: downloadedFiles)
        let hasChapters = referenceAvailability.hasChapters || episode.chapters?.isEmpty == false
        let hasTranscript = referenceAvailability.hasTranscript
            || episode.hasLoadedTranscript
            || episode.externalFiles.contains(where: { $0.category == .transcript })
        let hasBookmarks = episode.bookmarks?.isEmpty == false
        let progress = max(0.0, min(1.0, episode.displayProgress))
        let episodeTypeBadgeText = badgeText(for: episode.type)

        ZStack {
            BlurredCoverImageView(episode: episode)
                .scaledToFill()
                .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)
                //.opacity(0.45)
                .clipped()
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        CoverImageView(episode: episode)
                            .frame(width: artworkSize, height: artworkSize)
                            .accessibilityHidden(true)

                        if let episodeTypeBadgeText {
                            Text(episodeTypeBadgeText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary)
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
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            Text(publishText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(episode.title)
                            .font(.headline)
                            .lineLimit(4)
                            .foregroundStyle(.primary)

                        Spacer(minLength: 0)

                        Text(timeDisplay)
                            .font(.caption)
                            .foregroundStyle(.secondary)

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
                                .foregroundColor(.primary)
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, minHeight: artworkSize, alignment: .topLeading)
                }
                if Player.shared.currentEpisodeURL != episode.url {
                    EpisodeControlView(episode: episode)
                        .frame(minHeight: controlsHeight)
                }
            }
            .padding(8)
            .background(
                Rectangle()
                    .fill(.thinMaterial)
            )
            
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .overlay(alignment: .bottomLeading) {
            Rectangle()
                .fill(Color.accent)
                .scaleEffect(x: progress, y: 1, anchor: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: 4)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityHidden(true)
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
                                    .foregroundStyle(Color.primary)
                                    .font(.title.bold())
                            } else {
                                Label("Now Playing", systemImage: "waveform.low")
                                    .foregroundStyle(Color.primary)
                                    .font(.title.bold())
                            }
                        }
                        .frame(width: nowPlayingBadgeWidth, height: nowPlayingBadgeHeight)
              
                        
                    
             .background{
                 RoundedRectangle(cornerRadius:  20.0)
                     .fill(.background.opacity(differentiateWithoutColor ? 0.5 : 0.3))
             }
          
             
             .glassEffect(.clear, in: RoundedRectangle(cornerRadius:  20.0))
             .frame(maxWidth: nowPlayingBadgeWidth, maxHeight: nowPlayingBadgeHeight, alignment: .center)
            }
                
            }
            .onAppear {
                refreshReferenceAvailability()
            }
            .onChange(of: episode.url) { _, _ in
                refreshReferenceAvailability(invalidate: true)
            }
            .onChange(of: fileManager.downloadedFiles) { _, _ in
                refreshReferenceAvailability(invalidate: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .episodeReferencesDidChange).receive(on: DispatchQueue.main)) { notification in
                handleEpisodeReferencesDidChange(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .episodeDownloadFinished).receive(on: DispatchQueue.main)) { notification in
                handleEpisodeDownloadFinished(notification)
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
        var availability = EpisodeReferenceAvailability(
            hasChapters: episode.chapters?.isEmpty == false,
            hasTranscript: episode.hasLoadedTranscript
                || episode.externalFiles.contains(where: { $0.category == .transcript }),
            isDownloaded: isDownloaded(downloadedFiles: fileManager.downloadedFiles)
                || episode.metaData?.calculatedIsAvailableLocally == true
        )

        if let episodeURL = episode.url {
            let episodeDescriptor = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { candidate in
                    candidate.url == episodeURL
                }
            )
            if let matchingEpisodes = try? modelContext.fetch(episodeDescriptor),
               matchingEpisodes.isEmpty == false {
                availability.hasChapters = availability.hasChapters
                    || matchingEpisodes.contains { $0.chapters?.isEmpty == false }
                availability.hasTranscript = availability.hasTranscript
                    || matchingEpisodes.contains {
                        $0.hasLoadedTranscript
                            || $0.externalFiles.contains(where: { $0.category == .transcript })
                    }
                availability.isDownloaded = availability.isDownloaded
                    || matchingEpisodes.contains {
                        $0.metaData?.isAvailableLocally == true
                            || $0.metaData?.calculatedIsAvailableLocally == true
                    }
            }

            if availability.hasChapters == false {
                let chapterDescriptor = FetchDescriptor<Marker>(
                    predicate: #Predicate<Marker> { marker in
                        marker.episode?.url == episodeURL
                    }
                )
                availability.hasChapters = ((try? modelContext.fetchCount(chapterDescriptor)) ?? 0) > 0
            }

            if availability.hasTranscript == false {
                let transcriptDescriptor = FetchDescriptor<TranscriptLineAndTime>(
                    predicate: #Predicate<TranscriptLineAndTime> { line in
                        line.episode?.url == episodeURL
                    }
                )
                availability.hasTranscript = ((try? modelContext.fetchCount(transcriptDescriptor)) ?? 0) > 0
            }
        }

        if referenceAvailability != availability {
            referenceAvailability = availability
        }
        if invalidate {
            referenceRefreshID = UUID()
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
        refreshReferenceAvailability(invalidate: true)
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

private struct EpisodeReferenceAvailability: Equatable {
    var hasChapters = false
    var hasTranscript = false
    var isDownloaded = false
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
