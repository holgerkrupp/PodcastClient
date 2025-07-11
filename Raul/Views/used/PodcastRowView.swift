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
                
                PodcastCoverView(podcast:podcast)
                    .scaledToFill()
                    .id(podcast.id)
                
                    .frame(width: UIScreen.main.bounds.width * 0.9, height: 130)
                    .clipped()
                
                

                VStack(alignment: .leading){
                    HStack {
                        PodcastCoverView(podcast: podcast)
                            .frame(width: 50, height: 50)
                            .cornerRadius(8)
                        
                        
                        VStack(alignment: .leading) {
                            Text(podcast.title)
                                .font(.headline)
                            
                            if let author = podcast.author {
                                Text(author)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    if let desc = podcast.desc {
                        Text(desc)
                            .font(.caption)
                            .lineLimit(3)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
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
                }
                .frame(width: UIScreen.main.bounds.width * 0.9, height: 130)
                .padding()
                .background(
                    Rectangle()
                        .fill(.ultraThinMaterial)
                    // .shadow(radius: 3)
                )
            }
            
        
        .overlay {
            if podcast.metaData?.isUpdating  == true{
                ProgressView()
                    .frame(width: 100, height: 50)
                                          .scaledToFill()
                                          .background(Material.thin)
            }
        
        }
    }
}
