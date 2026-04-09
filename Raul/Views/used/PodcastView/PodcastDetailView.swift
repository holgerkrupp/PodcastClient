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
    @State private var backgroundUIImage: UIImage?
    @State private var isLoading = false
    @State private var refreshProgress: Double = 0
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
    @State private var filteredEpisodes: [Episode] = []
    @AppStorage("HidePlayedAndArchived") private var hidePlayedAndArchived: Bool = false

    
    init(podcast: Podcast) {
        self._podcast = Bindable(wrappedValue: podcast)
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
                        PodcastNamespaceMetadataView(optionalTags: podcast.optionalTags)
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
                            .accessibilityRemoveTraits(.isButton)
                        }

                        Button(podcast.isSubscribed ? "Unsubscribe" : "Subscribe") {
                            Task {
                                await toggleSubscriptionStatus()
                            }
                        }
                        .buttonStyle(.glass(.clear))

                        if podcast.isSubscribed == false {
                            Text("This podcast stays in the database, but it is skipped by bulk refresh.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                        NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                           EpisodeRowView(episode: episode)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open episode \(episode.title)")
                        .accessibilityHint("Opens this episode details screen")
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
                if let backgroundUIImage {
                    Image(uiImage: backgroundUIImage)
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
            .listRowSpacing(0)
            .padding(.top, 0)
            .searchable(text: $searchText)
            .task {
                applyEpisodeFilters()
            }
            .task(id: podcast.imageURL) {
                await loadBackgroundImage()
            }
            .onChange(of: searchText) { _, _ in
                debounceEpisodeFilters()
            }
            .onChange(of: searchInTitle) { _, _ in
                applyEpisodeFilters()
            }
            .onChange(of: searchInAuthor) { _, _ in
                applyEpisodeFilters()
            }
            .onChange(of: searchInDescription) { _, _ in
                applyEpisodeFilters()
            }
            .onChange(of: searchInTranscript) { _, _ in
                debounceEpisodeFilters()
            }
            .onChange(of: hidePlayedAndArchived) { _, _ in
                applyEpisodeFilters()
            }
            .onChange(of: sortOptionRawValue) { _, _ in
                applyEpisodeFilters()
            }
            .onChange(of: podcast.episodes?.count ?? 0) { _, _ in
                applyEpisodeFilters()
            }
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
                    .accessibilityLabel("Episode sort and visibility")
                    .accessibilityHint("Choose episode sort order and hide played episodes")
                    .accessibilityInputLabels([Text("Sort episodes"), Text("Episode sort")])
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        showSettings.toggle()
                    }) {
                        Image(systemName: "gear")
                    }
                    .accessibilityLabel("Podcast settings")
                    .accessibilityHint("Open settings for this podcast")
                    .accessibilityInputLabels([Text("Podcast settings"), Text("Open settings")])
                    
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        Task {
                            await refreshEpisodes()
                        }
                    }) {
                        if isLoading {
                            CircularProgressView(
                                value: max(refreshProgress, 0.02),
                                total: 1.0
                            )
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(podcast.isSubscribed == false || isLoading)
                    .accessibilityLabel(isLoading ? "Refreshing podcast" : "Refresh podcast")
                    .accessibilityHint("Downloads the latest episodes from this podcast feed")
                    .accessibilityInputLabels([Text("Refresh podcast"), Text("Update podcast")])
                    
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        Task {
                            try? await  PodcastModelActor(modelContainer: modelContext.container).archiveEpisodes(of: podcast.persistentModelID)
                        }
                    }) {
                        Image(systemName: "archivebox")
                    }
                    .accessibilityLabel("Archive all episodes")
                    .accessibilityHint("Marks all episodes in this podcast as archived")
                    .accessibilityInputLabels([Text("Archive all episodes"), Text("Archive podcast episodes")])
                }
                
                
            }
            .sheet(isPresented: $showSettings) {
               
  
                PodcastSettingsView(podcast: podcast, modelContainer: modelContext.container, embedInNavigationStack: true)
                        .presentationBackground(.ultraThinMaterial)
            
        }
        

    }

    private func debounceEpisodeFilters() {
        Debounce.shared.perform {
            applyEpisodeFilters()
        }
    }

    private func loadBackgroundImage() async {
        guard let imageURL = podcast.imageURL else {
            await MainActor.run {
                backgroundUIImage = nil
            }
            return
        }

        let uiImage = await ImageLoaderAndCache.loadUIImage(from: imageURL)
        await MainActor.run {
            backgroundUIImage = uiImage
        }
    }

    private func applyEpisodeFilters() {
        let episodes = podcast.episodes ?? []

        let visibleEpisodes: [Episode]
        if hidePlayedAndArchived {
            visibleEpisodes = episodes.filter { $0.maxPlayProgress < 0.95 }
        } else {
            visibleEpisodes = episodes
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else {
            filteredEpisodes = visibleEpisodes.sorted(by: sortOption.comparator)
            return
        }

        filteredEpisodes = visibleEpisodes
            .filter { episode in
                if searchInTitle, episode.title.localizedStandardContains(query) {
                    return true
                }
                if searchInAuthor, let author = episode.author, author.localizedStandardContains(query) {
                    return true
                }
                if searchInDescription, let desc = episode.desc, desc.localizedStandardContains(query) {
                    return true
                }
                if searchInTranscript,
                   let lines = episode.transcriptLines,
                   lines.contains(where: { $0.text.localizedStandardContains(query) }) {
                    return true
                }

                return false
            }
            .sorted(by: sortOption.comparator)
    }
    
    private func refreshEpisodes() async {
        guard podcast.isSubscribed else {
            return
        }

        isLoading = true
        refreshProgress = 0
        errorMessage = nil
        if let feed = podcast.feed{
            do {
                let actor = PodcastModelActor(modelContainer: modelContext.container)
                
                _ =  try await actor.updatePodcast(feed, force: true) { update in
                    await MainActor.run {
                        refreshProgress = update.fractionCompleted
                    }
                }
                podcast.message = nil
                
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to refresh episodes: \(error.localizedDescription)"
                }
            }
            
            await MainActor.run {
                isLoading = false
                refreshProgress = 0
            }
        }
    }

    private func toggleSubscriptionStatus() async {
        let actor = PodcastModelActor(modelContainer: modelContext.container)
        await actor.setSubscriptionStatus(podcast.persistentModelID, isSubscribed: !podcast.isSubscribed)
    }

}
