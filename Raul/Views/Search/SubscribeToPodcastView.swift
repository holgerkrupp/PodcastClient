//
//  SubscribeToPodcastView.swift
//  Raul
//
//  Created by Holger Krupp on 03.04.25.
//

import SwiftUI
import fyyd_swift
import SwiftData



struct SubscribeToPodcastView2: View {
    
    var body: some View {
            Text("Hello, World!")
    }
    
}



struct SubscribeToPodcastView: View {
    var formatStyle = Date.RelativeFormatStyle()
    @Environment(\.modelContext) private var context
    
    @State private var errorMessage: String?
    @State private var isSubscribed: Bool = false
    @State private var subscribing: Bool = false
    @State private var loading: Bool = false
    @Query private var allPodcasts: [Podcast]
    
    @Bindable var newPodcastFeed: PodcastFeed
    

    
    @State private var canBeSubscribed: Bool = false
    
    private var id: Int
    

    
    init(newPodcastFeed: PodcastFeed) {
        print("view is loaded with newPodcastFeed")
        id = newPodcastFeed.hashValue
        self.newPodcastFeed = newPodcastFeed
        

        self.canBeSubscribed = true
        _allPodcasts = Query()
    }
  
    
    var body: some View {
        
        
        
        if let url = newPodcastFeed.url, let podcast = allPodcasts.first(where: { $0.feed == url }){
            
            ZStack {
               
                PodcastRowView(podcast: podcast)
                
               NavigationLink(destination: PodcastDetailView(podcast: podcast)) {
                    EmptyView()
                }.opacity(0)
            
            }
        

            
        }else{
            ZStack{
                GeometryReader { geometry in
                    CoverImageView(imageURL: newPodcastFeed.artworkURL )
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: 200)
                        .clipped()
                }
                
                
                
                
                VStack(alignment: .leading){
                    HStack {
                        CoverImageView(imageURL: newPodcastFeed.artworkURL )
                            .frame(width: 150, height: 150)
                            .cornerRadius(8)
                        Spacer()
                        
                        VStack(alignment: .leading) {
                            Text(newPodcastFeed.title ?? "Untitled Podcast")
                                .font(.headline)
                            Spacer()
                            if let author = newPodcastFeed.artist {
                                Text(author)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            if let desc = newPodcastFeed.description {
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
                                            guard let url = newPodcastFeed.url else {
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
                                    .buttonStyle(.glass)
                                    
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
                if loading {
                    ZStack {
                        RoundedRectangle(cornerRadius:  8.0)
                            .fill(Color.clear)
                            .ignoresSafeArea()
                        VStack(alignment: .center) {
                            
                            ProgressView()
                                .frame(width: 100, height: 50)
                            Text("Loading...")
                                .padding()
                        }
                    }
                    .background{
                        RoundedRectangle(cornerRadius:  8.0)
                            .fill(.background.opacity(0.3))
                    }
                 
                    
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius:  8.0))
                    .frame(maxWidth: 300, maxHeight: 150, alignment: .center)
                }else if subscribing {
                    ZStack {
                        RoundedRectangle(cornerRadius:  8.0)
                            .fill(Color.clear)
                            .ignoresSafeArea()
                        VStack(alignment: .center) {
                            
                            ProgressView()
                                .frame(width: 100, height: 50)
                            Text("Subscribing...")
                                .padding()
                        }
                    }
                    .background{
                        RoundedRectangle(cornerRadius:  8.0)
                            .fill(.background.opacity(0.3))
                    }
                 
                    
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius:  8.0))
                    .frame(maxWidth: 300, maxHeight: 150, alignment: .center)
                } else if let errorMessage{
                    
                    ZStack {
                        RoundedRectangle(cornerRadius:  8.0)
                            .fill(Color.clear)
                            .ignoresSafeArea()
                        Text(errorMessage)
                            .padding()
                    }
                    .background{
                        RoundedRectangle(cornerRadius:  8.0)
                            .fill(.background.opacity(0.3))
                    }
                 
                    
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius:  8.0))
                    .frame(maxWidth: 300, maxHeight: 150, alignment: .center)

                }
            }
        }
        
        
      


    }
    

    
    
    private func requestNotification() async{
        let notificationManager = NotificationManager()
        await notificationManager.requestAuthorizationIfUndetermined()
    }
}

