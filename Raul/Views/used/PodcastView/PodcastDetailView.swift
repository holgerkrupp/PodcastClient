//
//  EpisodeView.swift
//  Raul
//
//  Created by Holger Krupp on 05.05.25.
//

import SwiftUI
import RichText

struct PodcastDetailView: View {
    
    enum EpisodeSortOption: String, CaseIterable, Identifiable {
        case newestFirst
        case oldestFirst
        case titleAZ
        case titleZA

        var id: String { rawValue }

        var label: String {
            switch self {
            case .newestFirst: return "Newest First"
            case .oldestFirst: return "Oldest First"
            case .titleAZ:     return "Title A–Z"
            case .titleZA:     return "Title Z–A"
            }
        }

        var comparator: (Episode, Episode) -> Bool {
            switch self {
            case .newestFirst:
                return { ($0.publishDate ?? .distantPast) > ($1.publishDate ?? .distantPast) }
            case .oldestFirst:
                return { ($0.publishDate ?? .distantFuture) < ($1.publishDate ?? .distantFuture) }
            case .titleAZ:
                return { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            case .titleZA:
                return { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
            }
        }
    }

    
    @Bindable var podcast: Podcast
    @State private var image: Image?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.deviceUIStyle) var style

    @State private var showSettings: Bool = false
    @AppStorage("EpisodeSortOption") private var sortOptionRawValue: String = EpisodeSortOption.newestFirst.rawValue
    private var sortOption: EpisodeSortOption {
        get { EpisodeSortOption(rawValue: sortOptionRawValue) ?? .newestFirst }
        set { sortOptionRawValue = newValue.rawValue }
    }
    
    @State private var searchText = ""
    @State private var searchInTitle = true
    @State private var searchInAuthor = false
    @State private var searchInDescription = true
    @State private var searchInTranscript = true
    @AppStorage("HidePlayedAndArchived") private var hidePlayedAndArchived: Bool = false

    var filteredEpisodes: [Episode] {
        let episodes = podcast.episodes ?? []

        // Apply optional hide filter first so search works on the visible set
        let visibilityFiltered: [Episode]
        if hidePlayedAndArchived {
            visibilityFiltered = episodes.filter { ep in
                let fullyPlayed = ep.maxPlayProgress >= 0.95
 
                return !(fullyPlayed)
            }
        } else {
            visibilityFiltered = episodes
        }

        // If there's no search text, just sort the visibility-filtered list
        if searchText.isEmpty {
            return visibilityFiltered.sorted(by: sortOption.comparator)
        }

        let lowercased = searchText.lowercased()

        // Apply search filters
        let searched = visibilityFiltered.filter { episode in
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
        }

        return searched.sorted(by: sortOption.comparator)
    }
    
    @StateObject private var backgroundImageLoader: ImageLoaderAndCache

    
    init(podcast: Podcast) {
        self._podcast = Bindable(wrappedValue: podcast)
        let imageURL = podcast.imageURL
        _backgroundImageLoader = StateObject(wrappedValue: ImageLoaderAndCache(imageURL: imageURL ?? URL(string: "about:blank")!))
    }
    
  
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
                                    .buttonStyle(.glass(.clear))
                                    
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
                            .buttonStyle(.glass(.clear))
                            .padding()
                        */
                        
                        if let copyright = podcast.copyright {
                            Text(copyright)
                                .font(.caption)
                        }
                        SocialView(socials: podcast.social)
                            .padding()
                        PeopleView(people: podcast.people)
                            .padding()
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
                            .buttonStyle(.glass(.clear))
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
                     
                        
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 20.0))
                        .frame(maxWidth: 300, maxHeight: 150, alignment: .center)
                    
                  
                        
                     
                    }
                
                }
                
                Section{
                    ForEach(filteredEpisodes, id: \.id) { episode in
                        
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
                                 let episodeID = filteredEpisodes[index].persistentModelID
                                    try? await PodcastModelActor(modelContainer: modelContext.container).deleteEpisode(episodeID)
                                
                            }
                        }
                    }
                }
                .listRowSeparator(.hidden)
            }
            .background{
                if let image = UIImage(data: backgroundImageLoader.imageData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity) // Ensure it takes up all available space
                                        .ignoresSafeArea(.all) // Crucial: extends the image behind safe areas (like under the status bar)
                                        
                        .blur(radius: 20)
                        .opacity(0.5)

                    
                } else {
                    Color.accent.ignoresSafeArea()
                }
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
                    Menu {
                        Picker("Sort by", selection: Binding(
                            get: { sortOptionRawValue },
                            set: { sortOptionRawValue = $0 }
                        )) {
                            ForEach(EpisodeSortOption.allCases) { option in
                                Text(option.label).tag(option.rawValue)
                            }
                        }
                        Divider()
                        Toggle(isOn: $hidePlayedAndArchived) {
                            Label("Hide played Episodes", systemImage: "eye.slash")
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
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
