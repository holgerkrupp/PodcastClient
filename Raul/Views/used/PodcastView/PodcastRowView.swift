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
        
        
            ZStack{
                

                
               
                    CoverImageView(podcast: podcast)
                        .scaledToFill()
                        .frame(height: 180)
                        .clipped()
                

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
                        
                        Spacer()
                    }
 
                }
                
               
                
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding()
                .background(
                    Rectangle()
                        .fill(.ultraThinMaterial)
                    
                )
                
                
                
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
}

