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
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.modelContext) private var modelContext

  
    var body: some View {


        List{
            Section{
                VStack(alignment: .leading) {
                    
                    HStack{
                        if let lastBuildDate = podcast.lastBuildDate {
                            Text("Last updated: \(lastBuildDate.formatted(date: .numeric, time: .shortened))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if let lastRefreshDate = podcast.metaData?.lastRefresh {
                            Text("Last refresh: \(lastRefreshDate.formatted(date: .numeric, time: .shortened))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    if let feedUpdateCheckDate = podcast.metaData?.feedUpdateCheckDate {
                        Text("Feed update check: \(feedUpdateCheckDate.formatted(date: .numeric, time: .shortened))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        
                        
                        if let imageURL = podcast.imageURL {
                            ImageWithURL(imageURL)
                                .frame(width: 50, height: 50)
                                .cornerRadius(8)
                        }
                        VStack{
                            if let author = podcast.author {
                                Text(author)
                                    .font(.caption)
                            }
                            Text(podcast.title)
                                .font(.headline)
                                .lineLimit(2)
                        }
                    }
                    if let podcastLink = podcast.link {
                        Link(destination: podcastLink) {
                            Text("Open in Safari")
                        }
                    }
                    
                    
                    
                    
                }
                if let copyright = podcast.copyright {
                    Text(copyright)
                        .font(.caption)
                }
            
                if let desc = podcast.desc {
                    ExpandableTextView(text: desc)
                        .font(.caption2)
                        .lineLimit(4)
                    
                }
            }
            .listRowSeparator(.hidden)
            Section{
                ForEach(podcast.episodes.sorted(by: {$0.publishDate ?? Date() > $1.publishDate ?? Date()}), id: \.id) { episode in
                   
                    ZStack {
                        EpisodeRowView(episode: episode)
                            .id(episode.id)
                        NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                            EmptyView()
                        }.opacity(0)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0,
                                         leading: 0,
                                         bottom: 2,
                                         trailing: 0))
                    .ignoresSafeArea()
                    
                }
                .onDelete { indexSet in
                    Task {
                        for index in indexSet {
                            let episodeID = podcast.episodes.sorted(by: {$0.publishDate ?? Date() > $1.publishDate ?? Date()})[index].persistentModelID
                            try? await PodcastModelActor(modelContainer: modelContext.container).deleteEpisode(episodeID)
                            
                        }
                    }
                }
            }
            .listRowSeparator(.hidden)
        }
        .listStyle(PlainListStyle())
        .padding(.top, 0)
     //   .navigationTitle(podcast.title)
        .refreshable {
            Task{
                await refreshEpisodes()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: {
                    Task {
                        await refreshEpisodes()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
               
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: {
                    Task {
                        try? await  PodcastModelActor(modelContainer: modelContext.container).archiveEpisodes(of: podcast.persistentModelID)
                    }
                }) {
                    Image(systemName: "archivebox")
                }
            }
            

        }


    }
    
    private func refreshEpisodes() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let actor = PodcastModelActor(modelContainer: modelContext.container)
          
                try await actor.updatePodcast(podcast.persistentModelID)
            
        } catch {
            await MainActor.run {
                errorMessage = "Failed to refresh episodes: \(error.localizedDescription)"
            }
        }
        
        await MainActor.run {
            isLoading = false
        }
    }

}

