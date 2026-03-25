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
        lhs.episode.id == rhs.episode.id &&
        lhs.episode.metaData?.lastPlayed == rhs.episode.metaData?.lastPlayed
    }
    @Environment(\.deviceUIStyle) var style
    @Environment(DownloadedFilesManager.self) var fileManager

    @Bindable var episode: Episode
    private let height:CGFloat = 210

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
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .blur(radius: 8)
                .opacity(0.45)
                .clipped()

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack(alignment: .topTrailing) {
                        CoverImageView(episode: episode)
                            .frame(width: 120, height: 120)

                        if hasBookmarks {
                            Image(systemName: "bookmark.fill")
                                .font(.title2)
                                .foregroundStyle(.accent)
                                .padding(8)
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
                            .lineLimit(3)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(.primary)

                        Spacer(minLength: 0)

                        Text(timeDisplay)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            if completionDate != nil {
                                Image("custom.play.circle.badge.checkmark")
                            } else if isDownloaded {
                                Image(systemName: style.sfSymbolName)
                            } else {
                                Image(systemName: "cloud")
                            }

                            if hasChapters {
                                Image(systemName: "list.bullet")
                            }
                            if hasTranscript {
                                Image(systemName: "quote.bubble")
                            }

                            Spacer()

                            DownloadControllView(episode: episode, showDelete: false)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundColor(.primary)
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                }

                EpisodeControlView(episode: episode)
                    .frame(height: 50)
            }
            .padding(8)
            .background(
                Rectangle()
                    .fill(.thinMaterial)
            )
        }
        .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        .overlay(alignment: .bottomLeading) {
            Rectangle()
                .fill(Color.accent)
                .scaleEffect(x: progress, y: 1, anchor: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: 4)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
            .overlay{


                if episode.url == Player.shared.currentEpisode?.url {
                        Group {
                            if Player.shared.isPlaying {
                                Label("Now Playing", systemImage: "waveform")
                                    .symbolEffect(.bounce.up.byLayer, options: .repeat(.continuous))
                                    .foregroundStyle(Color.primary)
                                    .font(.title.bold())
                            } else {
                                Label("Now Playing", systemImage: "waveform.low")
                                    .foregroundStyle(Color.primary)
                                    .font(.title.bold())
                            }
                        }
                        .frame(width: 300, height: 120)
              
                        
                    
             .background{
                 RoundedRectangle(cornerRadius:  20.0)
                     .fill(.background.opacity(0.3))
             }
          
             
             .glassEffect(.clear, in: RoundedRectangle(cornerRadius:  20.0))
             .frame(maxWidth: 300, maxHeight: 120, alignment: .center)
            }
                
            }

    }
    

}

#Preview {
    // Dummy Podcast
    let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
    podcast.title = "Sample Podcast"
    podcast.author = "Sample Author"
    podcast.desc = "A fun show about testing previews."

    // Dummy Episode
    let episode = Episode(
        id: UUID(),
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

    // Inject a dummy DownloadedFilesManager for preview
    let tempFolder = FileManager.default.temporaryDirectory
    let previewFilesManager = DownloadedFilesManager(folder: tempFolder)

    return EpisodeRowView(episode: episode)
        .environment(previewFilesManager)
}
