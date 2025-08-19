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
    @State private var subscribing: Bool = false
    @Query private var allPodcasts: [Podcast]
    
    @State var newPodcastFeed: PodcastFeed?
    @State var fyydPodcastFeed: FyydPodcast?
    
    @State private var title: String = ""
    @State private var imgURL: String? = nil
    @State private var author: String? = nil
    @State private var lastpub: Date? = nil
    @State private var description: String? = nil
    
    private var xmlURL: String
    
    @State private var canBeSubscribed: Bool = false
    
    private var id: Int
    
    init(fyydPodcastFeed: FyydPodcast) {
        id = fyydPodcastFeed.id
        self.fyydPodcastFeed = fyydPodcastFeed
        xmlURL =  fyydPodcastFeed.xmlURL ?? ""
        
        self._title = State(initialValue: fyydPodcastFeed.title ?? "")
        self._imgURL = State(initialValue: fyydPodcastFeed.imgURL)
        self._author = State(initialValue: fyydPodcastFeed.author)
        self._lastpub = State(initialValue: ISO8601DateFormatter().date(from: (fyydPodcastFeed.lastpub)))
        self._description = State(initialValue: fyydPodcastFeed.description)
        self.canBeSubscribed = true

        _allPodcasts = Query()
    }
    
    init(newPodcastFeed: PodcastFeed) {
        id = newPodcastFeed.hashValue
        self.newPodcastFeed = newPodcastFeed
        xmlURL =  newPodcastFeed.url?.absoluteString ?? ""
        
        self._title = State(initialValue: newPodcastFeed.title ?? "")
        self._imgURL = State(initialValue: newPodcastFeed.artworkURL?.absoluteString ?? "")
        self._author = State(initialValue: newPodcastFeed.artist)
        self._lastpub = State(initialValue: newPodcastFeed.lastRelease)
        self._description = State(initialValue: newPodcastFeed.description)
        self.canBeSubscribed = true
        _allPodcasts = Query()
    }
    
    private func fetchAndPopulateFeedIfNeeded() {
        guard let newPodcastFeed = newPodcastFeed, let url = newPodcastFeed.url else { return }
        // If we already have most information, skip
        let needsFetch = (newPodcastFeed.title?.isEmpty ?? true) || newPodcastFeed.artist == nil || newPodcastFeed.description == nil || newPodcastFeed.artworkURL == nil || newPodcastFeed.lastRelease == nil
        guard needsFetch else { return }
        Task {
            do {
                let parsed = try await PodcastParser.fetchAllPages(from: url)
                await MainActor.run {
                    // Assign parsed values to local state and newPodcastFeed
                    let newTitle = parsed["title"] as? String
                    let newDescription = parsed["description"] as? String
                    let newAuthor = (parsed["itunes:author"] as? String) ?? (parsed["author"] as? String)
                    let newArtwork = parsed["coverImage"] as? String
                    let newLastRelease = parsed["lastBuildDate"] as? String
                    self.title = newTitle ?? self.title
                    self.description = newDescription ?? self.description
                    self.author = newAuthor ?? self.author
                    self.imgURL = newArtwork ?? self.imgURL
                    if let lastBuildDateString = newLastRelease, let date = Date.dateFromRFC1123(dateString: lastBuildDateString) {
                        self.lastpub = date
                    }
                    // Update newPodcastFeed as well
                    self.newPodcastFeed?.title = newTitle ?? self.newPodcastFeed?.title
                    self.newPodcastFeed?.description = newDescription ?? self.newPodcastFeed?.description
                    self.newPodcastFeed?.artist = newAuthor ?? self.newPodcastFeed?.artist
                    if let newArtwork, let url = URL(string: newArtwork) {
                        self.newPodcastFeed?.artworkURL = url
                    }
                    if let lastBuildDateString = newLastRelease, let date = Date.dateFromRFC1123(dateString: lastBuildDateString) {
                        self.newPodcastFeed?.lastRelease = date
                    }
                    self.canBeSubscribed = true
                }
            } catch {
                await MainActor.run {
                    self.canBeSubscribed = false
                    self.errorMessage = "Failed to fetch podcast info: \(error.localizedDescription)"
                }
            }
        }
    }
    
    var body: some View {
        
        
        
        
        ZStack{
            GeometryReader { geometry in
                CoverImageView(imageURL: URL(string: imgURL ?? "") )
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: 200)
                    .clipped()
            }
     
 
            

            VStack(alignment: .leading){
                HStack {
                    CoverImageView(imageURL: URL(string: imgURL ?? "") )
                        .frame(width: 150, height: 150)
                        .cornerRadius(8)
                    Spacer()
                    
                    VStack(alignment: .leading) {
                        Text(title)
                            .font(.headline)
                        Spacer()
                        if let author = author {
                            Text(author)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        if let desc = description {
                            Text(desc)
                                .font(.caption)
                                .lineLimit(5)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        HStack{
                            Spacer()
                            
                                if !isSubscribed {
                                    Button("Subscribe") {
                                        
                                        Task {
                                            guard let url = URL(string: xmlURL) else {
                                                errorMessage = "Invalid URL"
                                                return
                                            }
                                            
                                            let actor = PodcastModelActor(modelContainer: context.container)
                                            do {
                                                subscribing = true
                                                _ = try await actor.createPodcast(from: url)
                                                await requestNotification()
                                                await MainActor.run {
                                                    isSubscribed = true
                                                    subscribing = false
                                                }
                                                
                                            } catch {
                                                errorMessage = error.localizedDescription
                                            }
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    
                                } else {
                                    Text("subscribed")
                                        .foregroundStyle(.secondary)
                                }
                            
                        }
                    }
                }

                 }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding()
            .background(
                Rectangle()
                    .fill(.ultraThinMaterial)
                // .shadow(radius: 3)
            )
        }
        .frame(height: 200)
        
        
      
        .overlay {
            if subscribing {
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
            if let errorMessage{
                ZStack {
                    Rectangle()
                        .fill(Material.ultraThin)
                        .ignoresSafeArea()
                    Text(errorMessage)
                        .font(.title2)
                     
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if let url = URL(string: xmlURL) {
                isSubscribed = allPodcasts.contains { $0.feed == url }
            }
            fetchAndPopulateFeedIfNeeded()
        }
    }
    
    private func requestNotification() async{
        let notificationManager = NotificationManager()
        await notificationManager.requestAuthorizationIfUndetermined()
    }
}

