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
    var newPodcastFeed: FyydPodcast
    var formatStyle = Date.RelativeFormatStyle()
    @Environment(\.modelContext) private var context
    
    @State private var errorMessage: String?
    @Query private var existingPodcasts: [Podcast]
    
    init(newPodcastFeed: FyydPodcast) {
        self.newPodcastFeed = newPodcastFeed
        let predicate: Predicate<Podcast>?
        if let xmlURL = newPodcastFeed.xmlURL, let url = URL(string: xmlURL) {
            predicate = #Predicate<Podcast> { $0.feed == url }
        } else {
            predicate = nil
        }
        _existingPodcasts = Query(filter: predicate)
    }
    
    var body: some View{
        VStack{
            Text(newPodcastFeed.title).font(.title3)

            if existingPodcasts.isEmpty {
                Button("Add Podcast") {
                    Task {
                        guard let url = URL(string: newPodcastFeed.xmlURL ?? "") else {
                            errorMessage = "Invalid URL"
                            return
                        }

                        let actor = PodcastModelActor(modelContainer: context.container)
                        do {
                            _ = try await actor.createPodcast(from: url)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            } else {
                Text("Already subscribed")
                    .foregroundStyle(.secondary)
            }
            
            HStack{
               
                if let image = newPodcastFeed.imgURL, let image = URL(string: image){
                    ImageWithURL(image)
                        .scaledToFit()
                        .frame(width: 50, height: 50)
                }
                
                VStack(alignment: .leading){
                    if let artist = newPodcastFeed.author{
                        Text(artist)
                            .font(.caption)
                    }
                    if let date = ISO8601DateFormatter().date(from: (newPodcastFeed.lastpub)){
                        Text("Last Release: \(date.formatted(formatStyle))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                }
                Spacer()

            }
         //   Text(newPodcastFeed.xmlURL ?? "").font(.caption)
            if let desc = newPodcastFeed.description{
                ExpandableTextView(text: desc)
                    .font(.caption2)
                    .lineLimit(2)
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
