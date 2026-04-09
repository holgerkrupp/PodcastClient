//
//  EpisodeRowView.swift
//  Raul
//
//  Created by Holger Krupp on 12.04.25.
//
import SwiftUI
import SwiftData

struct EpisodeRowView: View {
    static func == (lhs: EpisodeRowView, rhs: EpisodeRowView) -> Bool {
        lhs.episode.url == rhs.episode.url &&
        lhs.episode.metaData?.lastPlayed == rhs.episode.metaData?.lastPlayed
    }
    @Environment(\.deviceUIStyle) var style
    @Environment(DownloadedFilesManager.self) var fileManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    @Bindable var episode: Episode
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
        let podcastTitle = episode.podcast?.title ?? ""
        let publishText = episode.publishDate?.formatted(.relative(presentation: .named)) ?? ""
        let duration = episode.duration ?? 0.0
        let remainingTime = episode.remainingTime
        let showRemaining = remainingTime != nil && remainingTime != duration && (remainingTime ?? 0) > 0
        let timeText = Duration.seconds(showRemaining ? (remainingTime ?? 0) : duration).formatted(.units(width: .narrow))
        let timeDisplay = showRemaining ? timeText + " remaining" : timeText
        let completionDate = episode.metaData?.completionDate
        let isDownloaded = fileManager.isDownloaded(episode.localFile) == true
        let hasChapters = episode.chapters?.isEmpty == false
        let hasTranscript = episode.externalFiles.contains(where: { $0.category == .transcript }) || (episode.transcriptLines?.isEmpty == false)
        let hasBookmarks = episode.bookmarks?.isEmpty == false
        let progress = max(0.0, min(1.0, episode.maxPlayProgress))

        ZStack {
            CoverImageView(podcast: episode.podcast)
                .scaledToFill()
                .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)
                .blur(radius: 8)
                //.opacity(0.45)
                .clipped()
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack(alignment: .topTrailing) {
                        CoverImageView(episode: episode)
                            .frame(width: artworkSize, height: artworkSize)
                            .accessibilityHidden(true)

                        if hasBookmarks {
                            Image(systemName: "bookmark.fill")
                                .font(.title2)
                                .foregroundStyle(.accent)
                                .padding(8)
                                .accessibilityLabel("Has bookmarks")
                        }
                    }

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

                EpisodeControlView(episode: episode)
                    .frame(minHeight: controlsHeight)
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
