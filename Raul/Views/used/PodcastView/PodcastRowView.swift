//
//  PodcastRowView.swift
//  Raul
//
//  Created by Holger Krupp on 11.07.25.
//
import SwiftUI
import SwiftData

struct PodcastRowView: View {
    let podcast: Podcast

    var body: some View {
        ZStack {
            CoverImageView(podcast: podcast)
                .scaledToFill()
                .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 140)
                .blur(radius: 8)
                .opacity(0.45)
                .clipped()

            HStack(spacing: 14) {
                CoverImageView(podcast: podcast)
                    .frame(width: 112, height: 112)

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
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
            .background(
                Rectangle()
                    .fill(.thinMaterial)
            )
        }
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
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
