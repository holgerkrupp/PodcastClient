//
//  SubscribeToPodcastView.swift
//  Raul
//
//  Created by Holger Krupp on 03.04.25.
//

import SwiftUI
import fyyd_swift
import SwiftData

struct SubscribeToPodcastView: View {
    var formatStyle = Date.RelativeFormatStyle()
    @Environment(\.modelContext) private var context
    
    @State private var errorMessage: String?
    @State private var isSubscribed: Bool = false
    @Query private var allPodcasts: [Podcast]
    
    private var title: String
    private var xmlURL: String
    private var imgURL: String?
    private var author: String?
    private var lastpub: Date?
    private var description: String?
    
    init(fyydPodcastFeed: FyydPodcast) {
        title =  fyydPodcastFeed.title
        xmlURL =  fyydPodcastFeed.xmlURL ?? ""
        imgURL =  fyydPodcastFeed.imgURL
        lastpub = ISO8601DateFormatter().date(from: (fyydPodcastFeed.lastpub))
        author =  fyydPodcastFeed.author
        description =  fyydPodcastFeed.description
        _allPodcasts = Query()
    }
    
    init(newPodcastFeed: PodcastFeed) {
        title =  newPodcastFeed.title ?? ""
        xmlURL =  newPodcastFeed.url?.absoluteString ?? ""
        imgURL =  newPodcastFeed.artworkURL?.absoluteString ?? ""
        lastpub =  newPodcastFeed.lastRelease
        author =  newPodcastFeed.artist
        description =  newPodcastFeed.description
        _allPodcasts = Query()
    }
    
    var body: some View {
        VStack {
         Text(title).font(.title3)

            if !isSubscribed {
                Button("Add Podcast") {
                    Task {
                        guard let url = URL(string: xmlURL) else {
                            errorMessage = "Invalid URL"
                            return
                        }

                        let actor = PodcastModelActor(modelContainer: context.container)
                        do {
                            _ = try await actor.createPodcast(from: url)
                            isSubscribed = true
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            } else {
                Text("Already subscribed")
                    .foregroundStyle(.secondary)
            }
            
            HStack {
                if let image = imgURL, let image = URL(string: image) {
                    ImageWithURL(image)
                        .scaledToFit()
                        .frame(width: 50, height: 50)
                }
                
                VStack(alignment: .leading) {
                    if let artist = author {
                        Text(artist)
                            .font(.caption)
                    }
                    if let date = lastpub {
                        Text("Last Release: \(date.formatted(formatStyle))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            
            if let desc = description {
                ExpandableTextView(text: desc)
                    .font(.caption2)
                    .lineLimit(2)
            }
            
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
        .onAppear {
            if let url = URL(string: xmlURL) {
                isSubscribed = allPodcasts.contains { $0.feed == url }
            }
        }
    }
}

struct ExpandableTextView: View {
    @State private var isExpanded = false
    @Environment(\.lineLimit) private var externalLineLimit
    var text: String
    
    var body: some View {
        VStack {
            Text(text)
                .lineLimit(isExpanded ? nil : externalLineLimit) // Use the maxLines parameter
              
            
            if text.count > 100 { // Optional: only show "Read More" if the text is long enough
                Button(action: {
                    isExpanded.toggle()
                }) {
                    Text(isExpanded ? "Show Less" : "Show More")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.top, 5)
                }
            }
        }
    }
}
