//
//  EpisodeView.swift
//  Raul
//
//  Created by Holger Krupp on 05.05.25.
//

import SwiftUI
import RichText

struct PodcastDetailView: View {

    
    @Bindable var podcast: Podcast
    @State private var image: Image?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.deviceUIStyle) var style

    @State private var showSettings: Bool = false
    
    @State private var searchText = ""
    @State private var searchInTitle = true
    @State private var searchInAuthor = false
    @State private var searchInDescription = true
    @State private var searchInTranscript = true

    var filteredPodcasts: [Episode] {
        if searchText.isEmpty { return podcast.episodes ?? [] }

        return podcast.episodes?.filter { episode in
            let lowercased = searchText.lowercased()

            var matches = false
            if searchInTitle {
                matches = matches || episode.title.localizedStandardContains(lowercased)
            }
            if searchInDescription, let desc = episode.desc {
                matches = matches || desc.localizedStandardContains(lowercased)
            }
            if searchInTranscript, let lines = episode.transcriptLines {
                matches = matches || lines.contains(where: { $0.text.localizedStandardContains(lowercased)})
            }

            return matches
        } ?? []
    }
    
    @StateObject private var backgroundImageLoader: ImageLoaderAndCache

    
    init(podcast: Podcast) {
        self._podcast = Bindable(wrappedValue: podcast)
        let imageURL = podcast.imageURL
        _backgroundImageLoader = StateObject(wrappedValue: ImageLoaderAndCache(imageURL: imageURL ?? URL(string: "about:blank")!))
    }
    
  
    var body: some View {
        GeometryReader { geometry in
        
        ZStack {
            if let image = UIImage(data: backgroundImageLoader.imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                
                
                
            } else {
                Color.accentColor.ignoresSafeArea()
            }
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            
            
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
                            if let metaData = podcast.metaData, let lastRefreshDate = metaData.feedUpdateCheckDate {
                                Text("Last refresh: \(lastRefreshDate.formatted(date: .numeric, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        HStack {
                            
                            CoverImageView(podcast: podcast)
                                .frame(width: 50, height: 50)
                                .cornerRadius(8)
                            
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
                        if podcast.funding.count > 0 {
                            HStack{
                                ForEach(podcast.funding ) { fund in
                                    Link(destination: fund.url) {
                                        Label(fund.label, systemImage: style.currencySFSymbolName)
                                    }
                                    .buttonStyle(.glass)
                                    
                                    if fund != podcast.funding.last {
                                        Spacer()
                                    }
                                }
                            }
                        }
                        /*
                    
                            NavigationLink(destination: BookmarkListView(podcast: podcast)) {
                                Label("Show Bookmarks", systemImage: "bookmark.fill")
                                   
                            }
                            .buttonStyle(.glass)
                            .padding()
                        */
                        
                        if let copyright = podcast.copyright {
                            Text(copyright)
                                .font(.caption)
                        }
                        
                        if let desc = podcast.desc {
                            RichText(html: desc)
                                .linkColor(light: Color.secondary, dark: Color.secondary)
                                .backgroundColor(.transparent)
                                .padding()
                            
                            
                        }
                        if let podcastLink = podcast.link {
                            Link(destination: podcastLink) {
                                Label("Open in Browser", systemImage: "safari")
                            }
                            .buttonStyle(.glass)
                        }
                    }
                }
                .listRowSeparator(.hidden)
                .background(.clear)
                .listRowBackground(Color.clear)
                .overlay {
                    if  let message = podcast.message {
                        
                        ZStack {
                            RoundedRectangle(cornerRadius:  8.0)
                                .fill(Color.clear)
                                .ignoresSafeArea()
                            HStack(alignment: .center) {
                                
                                ProgressView()
                                    .frame(width: 100, height: 50)
                                Text(message)
                                    .foregroundStyle(Color.primary)
                                    .font(.title.bold())
                                    
                            }
                        }
                        .background{
                            RoundedRectangle(cornerRadius:  8.0)
                                .fill(.background.opacity(0.3))
                        }
                     
                        
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius:  8.0))
                        .frame(maxWidth: 300, maxHeight: 150, alignment: .center)
                    
                  
                        
                     
                    }
                
                }
                
                Section{
                    ForEach(filteredPodcasts.sorted(by: {$0.publishDate ?? Date() > $1.publishDate ?? Date()}), id: \.id) { episode in
                        
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
                                             bottom: 0,
                                             trailing: 0))
                        .ignoresSafeArea()
                        
                        
                    }
                    .onDelete { indexSet in
                        Task {
                            for index in indexSet {
                                if let episodeID = podcast.episodes?.sorted(by: {$0.publishDate ?? Date() > $1.publishDate ?? Date()})[index].persistentModelID{
                                    try? await PodcastModelActor(modelContainer: modelContext.container).deleteEpisode(episodeID)
                                }
                            }
                        }
                    }
                }
                .listRowSeparator(.hidden)
            }
  
            .listStyle(PlainListStyle())
            .padding(.top, 0)
            .searchable(text: $searchText)
            .navigationTitle(podcast.title)
            .refreshable {
                Task{
                    await refreshEpisodes()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        showSettings.toggle()
                    }) {
                        Image(systemName: "gear")
                    }
                    
                }
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
            .sheet(isPresented: $showSettings) {
               
  
                PodcastSettingsView(podcast: podcast, modelContainer: modelContext.container)
                        .presentationBackground(.ultraThinMaterial)
            
        }
        }}

    }
    
    private func refreshEpisodes() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let actor = PodcastModelActor(modelContainer: modelContext.container)
          
               _ =  try await actor.updatePodcast(podcast.id, force: true)
            podcast.message = nil
            
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
