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

        HStack(spacing: 14) {
            CoverImageView(podcast: podcast)
                .frame(width: artworkSize, height: artworkSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(podcast.title)
                    .font(.headline)
                    .lineLimit(2)

                if let author = podcast.author, author.isEmpty == false {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let desc = podcast.desc, desc.isEmpty == false {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .ESA_RowView(image: podcast.imageURL, minHeight: rowHeight)
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
                            .foregroundStyle(Color.primary)
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
