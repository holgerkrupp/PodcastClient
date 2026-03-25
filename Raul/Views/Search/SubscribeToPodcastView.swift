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
    
    @State private var errorMessage: String?
    @State private var subscribing: Bool = false
    @State private var subscriptionProgress: Double = 0
    @State private var subscriptionMessage = "Preparing subscription"
    @Query private var allPodcasts: [Podcast]
    
    @Bindable var newPodcastFeed: PodcastFeed
    

    
    @State private var canBeSubscribed: Bool = false
    
    private var id: Int
    

    
    init(newPodcastFeed: PodcastFeed) {
 
        id = newPodcastFeed.hashValue
        self.newPodcastFeed = newPodcastFeed
        

        self.canBeSubscribed = true
        _allPodcasts = Query()
    }
  
    
    var body: some View {
       
        
        
        
        if let url = newPodcastFeed.url, let podcast = allPodcasts.first(where: { $0.feed == url }){
         
           
               
                PodcastRowView(podcast: podcast)
                
   
            
            
        

            
        }else{
            ZStack{
                
                CoverImageView(imageURL: newPodcastFeed.artworkURL )
                    .scaledToFill()
                    .frame(height: 200)
                    .clipped()
                
                
                
                
                
                VStack(alignment: .leading){
                    HStack {
                        CoverImageView(imageURL: newPodcastFeed.artworkURL )
                            .frame(width: 150, height: 150)
                            .cornerRadius(8)
                        
                        
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
                                
                                
                                Button("Subscribe") {
                                    
                                    Task {
                                        guard newPodcastFeed.url != nil else {
                                            errorMessage = "Invalid URL"
                                            return
                                        }

                                        await MainActor.run {
                                            errorMessage = nil
                                            subscribing = true
                                            subscriptionProgress = 0
                                            subscriptionMessage = "Preparing subscription"
                                        }

                                        await SubscriptionManager(modelContainer: ModelContainerManager.shared.container).subscribe(all: [newPodcastFeed]) { update in
                                            await MainActor.run {
                                                subscriptionProgress = update.fractionCompleted
                                                subscriptionMessage = update.message
                                            }
                                        }

                                        await requestNotification()
                                        await MainActor.run {
                                            subscribing = false
                                        }
                                    }
                                }
                                .buttonStyle(.glass(.clear))
                                .disabled(subscribing)
                                
                                
                                
                            }
                        }
                        .padding()
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
                        RoundedRectangle(cornerRadius:  8.0)
                            .fill(Color.clear)
                            .ignoresSafeArea()
                        VStack(alignment: .center) {
                            ProgressView(value: max(subscriptionProgress, 0.02), total: 1.0)
                                .frame(width: 180)
                            Text(subscriptionMessage)
                                .padding(.top, 8)
                            Text("\(Int(subscriptionProgress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                    .background{
                        RoundedRectangle(cornerRadius:  8.0)
                            .fill(.background.opacity(0.3))
                    }
                    
                    
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 20.0))
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
                    
                    
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 20.0))
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
