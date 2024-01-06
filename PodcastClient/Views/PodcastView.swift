//
//  PodcastView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 06.12.23.
//

import SwiftUI
import SwiftData

struct PodcastView: View {
    
    @Environment(\.modelContext) var modelContext
    @Query var podcasts: [Podcast]
    var podcast: Podcast? { podcasts.first}
    var subscriptionManager = SubscriptionManager.shared
    
    
    
    init(for podcastID: PersistentIdentifier) {
        
        
        self._podcasts = Query(filter: #Predicate<Podcast> {
            $0.persistentModelID == podcastID
        })
        
    }
    
    var body: some View {
        List{
            Text(podcast?.title ?? "").font(.title)
            
                    HStack{
                        if let imageULR = podcast?.coverURL{
                            ImageWithURL(imageULR)
                                .scaledToFit()
                                .frame(width: 100, height: 100)
                        }else{
                            Image(systemName: "mic.fill")
                                .scaledToFit()
                                .frame(width: 100, height: 100)
                        }
                        VStack{
                            
                            Text(podcast?.author ?? "").font(.caption)
                            Spacer()
                            Text(podcast?.subtitle ?? "").font(.subheadline)
                            Spacer()
                            if let weblink = podcast?.link{
                                Link(destination: weblink, label: {
                                    HStack{
                                        Image(systemName: "safari")
                                        Text(weblink.host() ?? "Website")
                                    }
                                })
                                .buttonStyle(.bordered)
                            }
                            
                        }
                    }.listRowSeparator(.hidden)
            Text(podcast?.summary ?? "")
            Button {
                if let podcast{
                    subscriptionManager.refresh(podcast: podcast)
                }
            } label: {
                if podcast?.isUpdating == true{
                    ProgressView()
                }else{
                    Text("Refresh Content")
                }
            }
            .buttonStyle(.bordered)
           
                    HStack{
                        Spacer()
                        Button {
                            print("Settings")
                        } label: {
                            Text("Settings")
                        }
                        .buttonStyle(.bordered)
                        
                        Spacer()
                        
                        Button {
                            print("Unsubscribe")
                        } label: {
                            Text("Unsubscribe")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }.listRowSeparator(.hidden)
 
              
            Section {
                ForEach(podcast?.episodes.sorted(by: { $0.pubDate ?? Date() > $1.pubDate ?? Date()}) ?? []){ episode in
                    NavigationLink {
                        EpisodeView()
                            .environment(EpisodeModel(episode: episode))
                        
                    }label:{
                        EpisodeMiniView()
                            .environment(EpisodeModel(episode: episode))
                    }
                }
            } header: {
                Text("Episodes")
            } footer: {
                Text("\(podcast?.episodes.count.description ?? "") Episodes").listRowSeparator(.hidden).font(.footnote)
            }


        }.listStyle(.plain)
                
                
            
        
    }

}



struct PodcastMiniView: View {
    
   
    var podcast: Podcast
    
    var body: some View {
        HStack{
            if let imageULR = podcast.coverURL{
                ImageWithURL(imageULR)
                    .scaledToFit()
                    .frame(width: 50, height: 50)
                
            }
            VStack(alignment: .leading){
                Text(podcast.title)
                Text(podcast.lastHTTPcode?.description ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
            }
        }
    }

}
