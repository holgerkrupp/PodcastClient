//
//  PodcastRowView.swift
//  Raul
//
//  Created by Holger Krupp on 11.07.25.
//
import SwiftUI
import SwiftData
import ESADesignKit

struct PodcastRowView: View {
    let podcast: Podcast
    var previewArtwork: Image? = nil
    var previewArtworkSource: ESAImageSource? = nil
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.esaVisualStyle) private var visualStyle
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 140
    @ScaledMetric(relativeTo: .body) private var artworkSize: CGFloat = 112

    private func abandonmentLabel(for assessment: PodcastFeedAbandonmentAssessment) -> String {
        switch assessment.kind {
        case .unavailableFeed:
            return "Unavailable"
        case .likelyCancelled:
            return "Possibly Cancelled"
        }
    }

    var body: some View {
        let abandonmentAssessment = podcast.metaData?.feedAbandonmentAssessment
        let isAbandoned = abandonmentAssessment != nil

        let rowContent = ZStack {
            if visualStyle == .artwork && colorSchemeContrast == .increased {
                Rectangle()
                    .fill(Color(white: colorScheme == .dark ? 0 : 1))
                    .accessibilityHidden(true)
            } else if visualStyle == .artwork {
                Group {
                    if let previewArtwork {
                        previewArtwork
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 18)
                    } else {
                        BlurredCoverImageView(
                            podcast: podcast,
                            maxPixelSize: 512,
                            loadDelay: .milliseconds(200)
                        )
                    }
                }
                    .scaledToFill()
                    .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)
                    .clipped()
                    .accessibilityHidden(true)
            }

            HStack(spacing: 14) {
                Group {
                    if let previewArtwork {
                        previewArtwork
                            .resizable()
                            .scaledToFit()
                    } else {
                        CoverImageView(
                            podcast: podcast,
                            maxPixelSize: 384,
                            loadDelay: .milliseconds(200)
                        )
                    }
                }
                    .frame(width: artworkSize, height: artworkSize)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    Text(podcast.title)
                        .font(.headline)
                        .lineLimit(2)
                        .esaForeground(.primary)

                    if let author = podcast.author, author.isEmpty == false {
                        Text(author)
                            .font(.subheadline)
                            .esaForeground(.secondary)
                            .lineLimit(1)
                    }

                    if let desc = podcast.desc, desc.isEmpty == false {
                        Text(desc.plainTextFromHTML() ?? desc)
                            .font(.caption)
                            .esaForeground(.secondary)
                            .lineLimit(3)
                    }

                    if podcast.isSubscribed == false {
                        Label("Not Subscribed", systemImage: "pause.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
            .background {
                if visualStyle == .artwork && colorSchemeContrast == .standard {
                    Rectangle().fill(.thinMaterial)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .grayscale(isAbandoned ? 1 : 0)
        .overlay(alignment: .topLeading) {
            if let abandonmentAssessment {
                let label = abandonmentLabel(for: abandonmentAssessment)
                Text(label)
                    .font(.caption2.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.85), in: UnevenRoundedRectangle(bottomTrailingRadius: 8))
                    .accessibilityLabel(label)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let feedIssueDescription {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(9)
                    .accessibilityLabel(feedIssueDescription)
                    .help(feedIssueDescription)
            }
        }
        .overlay {
            if  let message = podcast.message {
                ZStack {
                    RoundedRectangle(cornerRadius:  8.0)
                        .fill(Color.clear)
                        .ignoresSafeArea()
                    HStack(alignment: .center) {
                        
                        ProgressView()
                            .frame(width: 100, height: 50)
                        Text(message)
                            .esaForeground(.primary)
                            .font(.title.bold())
                            
                    }
                        }
                        .background{
                            RoundedRectangle(cornerRadius:  8.0)
                                .fill(.background.opacity(0.3))
                        }
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 20.0))
                        .frame(maxWidth: 300, maxHeight: 150, alignment: .center)
            }
        }

        if visualStyle == .artwork {
            rowContent
        } else if let previewArtworkSource {
            ESARowView(image: previewArtworkSource, minHeight: rowHeight) {
                rowContent
            }
        } else {
            rowContent.ESA_RowView(image: podcast.imageURL, minHeight: rowHeight)
        }
    }

    private var feedIssueDescription: String? {
        if let assessment = podcast.metaData?.feedAbandonmentAssessment,
           assessment.kind == .unavailableFeed {
            return "\(assessment.title). \(assessment.detail)"
        }
        guard let metadata = podcast.metaData,
              metadata.lastFeedFailureDate != nil else {
            return nil
        }

        let reason = metadata.feedFailureStatusDescription
            ?? metadata.lastFeedFailureMessage
            ?? "The podcast feed could not be refreshed."
        return "Podcast feed issue: \(reason)"
    }
}

#Preview {
    let metaData: PodcastMetaData = {
        let metaData = PodcastMetaData()
        metaData.feedUpdateCheckDate = Date().addingTimeInterval(-3600) // 1 hour ago
        metaData.consecutiveFeedFailureCount = 4
        metaData.firstConsecutiveFeedFailureDate = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        metaData.lastFeedFailureDate = Date().addingTimeInterval(-3600)
        metaData.lastFeedFailureStatusCode = 404
        metaData.isUpdating = false
        return metaData
    }()

    let podcast: Podcast = {
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        podcast.title = "Swift Over Coffee"
        podcast.author = "Paul Hudson & Sean Allen"
        podcast.desc = "A show about Swift, iOS development, and general Apple nerdery."
        podcast.lastBuildDate = Date().addingTimeInterval(-7200) // 2 hours ago
        podcast.imageURL = nil // Or provide a sample image URL if your PodcastCoverView handles it
        podcast.metaData = metaData
        return podcast
    }()

    PodcastRowView(podcast: podcast)
        .padding()
}
