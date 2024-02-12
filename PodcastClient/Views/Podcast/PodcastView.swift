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
    var subscriptionManager = SubscriptionManager()
    var podcast: Podcast
    /*
    @Query var podcasts: [Podcast]
    var podcast: Podcast? { podcasts.first}
    var subscriptionManager = SubscriptionManager()
    
    
    
    init(for podcastID: PersistentIdentifier) {
        
        
        self._podcasts = Query(filter: #Predicate<Podcast> {
            $0.persistentModelID == podcastID
        })
        
    }
    */
    var body: some View {
        List{
          //  if let podcast{
                Menu{
                    PodcastMetaDataView(podcast: podcast)
                }label:{
                    Image(systemName: "line.3.horizontal")
                }
                
                
                
                //   Text(podcast?.title ?? "").font(.title)
                
                HStack{
                    if let data = podcast.cover{
                        ImageWithData(data)
                            .scaledToFit()
                            .frame(width: 100, height: 100)
                    }else if let imageULR = podcast.coverURL{
                        ImageWithURL(imageULR)
                            .scaledToFit()
                            .frame(width: 100, height: 100)
                    }else{
                        Image(systemName: "mic.fill")
                            .scaledToFit()
                            .frame(width: 100, height: 100)
                    }
                    
                    VStack(alignment: .trailing){
                        
                        Text(podcast.author ?? "").font(.caption)
                        Spacer()
                        Text(podcast.subtitle ?? "").font(.subheadline)
                        Spacer()
                        if let weblink = podcast.link{
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
                Text(podcast.summary ?? "")
                HStack{
                    Button {
                        Task{
                            await subscriptionManager.refresh(podcast: podcast)
                        }
                    } label: {
                        Label {
                            Text("Refresh")
                        } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 20)
                                .rotationEffect(.degrees(podcast.isUpdating ?? false ? 360 : 0))
                                .animation(.easeInOut(duration: 1), value: podcast.isUpdating ?? false)
                        }
                        .labelStyle(.iconOnly)
                        
                    }
                    .buttonStyle(.bordered)
                    Button {
                            podcast.markAllAsPlayed()
                        
                    } label: {
                        
                        Label {
                            Text("Mark All As Played")
                        } icon: {
                            Image(systemName: "circlebadge.2.fill")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 20)
                            
                            
                        }
                        .labelStyle(.iconOnly)
                        
                        
                    }
                    .buttonStyle(.bordered)
                    

                   
                    Spacer()
                    Button {
                        print("Settings")
                        PodcastSettingsView(settings: podcast.settings ?? PodcastSettings(podcast: podcast))
                    } label: {
                        Label {
                            Text("Settings")
                        } icon: {
                            Image(systemName: "gear")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 20)
                            
                            
                        }
                        .labelStyle(.iconOnly)
                        
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    Button {
                        print("Unsubscribe")
                    } label: {
                        Text("Unsubscribe")
                            .frame(maxHeight: 20)
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }.listRowSeparator(.hidden)
                
                
                Section {
                    
                    ListofEpisodesView(episodes: podcast.episodes.sorted(by: { $0.pubDate ?? Date() > $1.pubDate ?? Date()}) )
                        .modelContext(modelContext)
                    
                } header: {
                    Text("\(podcast.episodes.count.description ) Episodes")
                }
                
                
           // }
                
            }.listStyle(.plain)
                .navigationTitle(Text(podcast.title ?? ""))
            
            
            
        
    }

}

struct PodcastMetaDataView: View{
    
    var podcast: Podcast
    
    var body: some View {
        VStack{
            HStack{
                Text("Last Build Date")
                Text(podcast.lastBuildDate?.formatted() ?? "-")
            }
            
            
            HStack{
                Text("Last Modified")
                Text(podcast.lastModified?.formatted() ?? "-")
            }
            HStack{
                Text("Last Refresh")
                Text(podcast.lastRefresh?.formatted() ?? "-")
            }
            HStack{
                Text("Last Attempt")
                Text(podcast.lastAttempt?.formatted() ?? "-")
            }
            HStack{
                Text("Counter")
                Text(podcast.DEBUGAttemptCount.formatted())
            }
            
            HStack{
                Text("Last HTTP StatusCode")
                Text(podcast.lastHTTPcode?.formatted() ?? "-")
            }
        }
    }
}



struct PodcastMiniView: View {
    
   
    @State var podcast: Podcast
    
    var body: some View {
        HStack{
            if let data = podcast.cover{
                ImageWithData(data)
                    .scaledToFit()
                    .frame(width: 50, height: 50)
            }else if let imageULR = podcast.coverURL{
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
