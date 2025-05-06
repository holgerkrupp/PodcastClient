//
//  EpisodeView.swift
//  Raul
//
//  Created by Holger Krupp on 05.05.25.
//

import SwiftUI

struct PodcastDetailView: View {
    @State var podcast: Podcast
    @State private var image: Image?
    var body: some View {
        HStack {
            Group {
                if let image = image {
                    image
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.gray.opacity(0.2)
                }

            }
            .frame(width: 50, height: 50)
            .task {
                await loadImage()
            }
            
            VStack(alignment: .leading) {
                if let author = podcast.author {
                    Text(author)
                        .font(.caption)
                }
                Text(podcast.title)
                    .font(.headline)
                    .lineLimit(2)

                if let podcastLink = podcast.link {
                    Link(destination: podcastLink) {
                        Text("Open in Safari")
                    }
                }


              
            }
        }
        if let copyright = podcast.copyright {
            Text(copyright)
                .font(.caption)
        }
        Divider()
        if let desc = podcast.desc {
            ExpandableTextView(text: desc)
                .font(.caption2)
                .lineLimit(4)
        }
       
        

    }
    private func loadImage() async {
        if let imageURL = podcast.coverImageURL  {
            if let uiImage = await ImageLoader.shared.loadImage(from: imageURL) {
                await MainActor.run {
                    self.image = Image(uiImage: uiImage)
                }
            }
        }
    }
}
