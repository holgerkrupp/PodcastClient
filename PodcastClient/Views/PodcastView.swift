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
    
    init(for podcastID: PersistentIdentifier) {
        
        
        self._podcasts = Query(filter: #Predicate<Podcast> {
            $0.persistentModelID == podcastID
        })
        
    }
    
    var body: some View {
        List{
            Text(podcast?.author ?? "").font(.caption)
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
                            
                            Text(podcast?.title ?? "").font(.title)
                            Text(podcast?.subtitle ?? "").font(.subheadline)
                            Spacer()
                            if let weblink = podcast?.link{
                                Link(destination: weblink, label: {
                                    HStack{
                                        Image(systemName: "safari")
                                        Text("Website")
                                    }
                                })
                            }
                            
                        }
                    }.listRowSeparator(.hidden)
            Text(podcast?.summary ?? "")
           
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
                        EpisodeView(episode: episode)
                        
                    }label:{
                        EpisodeMiniView(episode: episode)
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
            VStack{
                Text(podcast.title)
                
                
            }
        }
    }

}
