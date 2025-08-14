//
//  PodcastRowView.swift
//  Raul
//
//  Created by Holger Krupp on 11.07.25.
//
import SwiftUI

struct PodcastRowView: View {
    let podcast: Podcast
    
    var body: some View {
        
        
            ZStack{
                

                
                GeometryReader { geometry in
                    CoverImageView(podcast: podcast)
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: 180)
                        .clipped()
                }

                VStack(alignment: .leading){
                    HStack {
                        CoverImageView(podcast: podcast)
                            .frame(width: 150, height: 150)
                            .cornerRadius(8)
                        
                        
                        VStack(alignment: .leading) {
                            Text(podcast.title)
                                .font(.headline)
                            Spacer()
                            if let author = podcast.author {
                                Text(author)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            if let desc = podcast.desc {
                                Text(desc)
                                    .font(.caption)
                                    .lineLimit(5)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                        }
                        .frame(height: 150)
                    }
                    /*
                    HStack{
                        if let lastBuildDate = podcast.lastBuildDate {
                            Text("Last updated: \(lastBuildDate.formatted(.relative(presentation: .named)))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if let lastRefreshDate = podcast.metaData?.feedUpdateCheckDate {
                            Text("Last checked: \(lastRefreshDate.formatted(.relative(presentation: .named)))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                     */
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding()
                .background(
                    Rectangle()
                        .fill(.ultraThinMaterial)
                    
                )
                
                
                
            }
            
            
        
        .overlay {
            if podcast.metaData?.isUpdating == true {
                ZStack {
                    Rectangle()
                        .fill(Material.ultraThin)
                        .ignoresSafeArea()
                    ProgressView()
                        .frame(width: 100, height: 50)
                     //   .background(Material.ultraThin)
                       // .cornerRadius(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        
        }
    }
}

#Preview {
    // Create a dummy PodcastMetaData for preview
    let metaData = PodcastMetaData()
    metaData.feedUpdateCheckDate = Date().addingTimeInterval(-3600) // 1 hour ago
    metaData.isUpdating = false

    // Create a dummy Podcast
    let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
    podcast.title = "Swift Over Coffee"
    podcast.author = "Paul Hudson & Sean Allen"
    podcast.desc = "A show about Swift, iOS development, and general Apple nerdery."
    podcast.lastBuildDate = Date().addingTimeInterval(-7200) // 2 hours ago
    podcast.imageURL = nil // Or provide a sample image URL if your PodcastCoverView handles it
    podcast.metaData = metaData

    return PodcastRowView(podcast: podcast)
        .padding()
        .previewLayout(.sizeThatFits)
}
