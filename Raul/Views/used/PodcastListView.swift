import SwiftUI
import SwiftData

struct PodcastListView: View {
    enum LibraryScope: String, CaseIterable, Identifiable {
        case subscribed
        case unsubscribed
        case all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .subscribed:
                return "Subscribed"
            case .unsubscribed:
                return "Not Subscribed"
            case .all:
                return "All"
            }
        }
    }

    @Query(sort: \Podcast.title) private var podcasts: [Podcast]
    @StateObject private var viewModel: PodcastListViewModel
    
    @State private var filteredPodcasts: [Podcast] = []
    @State private var episodeSearchResults: [EpisodeSearchResult] = []
    @State private var selectedScope: LibraryScope = .subscribed
    @State private var searchText = ""
    @State private var searchInTitle = true
    @State private var searchInAuthor = false
    @State private var searchInDescription = true
    @State private var searchInEpisodes = true
    @State private var searchTask: Task<Void, Never>?

    init(modelContainer: ModelContainer) {
        _viewModel = StateObject(wrappedValue: PodcastListViewModel(modelContainer: modelContainer))
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearchingEpisodes: Bool {
        trimmedSearchText.isEmpty == false && searchInEpisodes
    }

    var body: some View {
        Group {
            if isSearchingEpisodes {
                if episodeSearchResults.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("No episodes matched \"\(trimmedSearchText)\".")
                    )
                } else {
                    List {
                        ForEach(episodeSearchResults) { result in
                            episodeResultRow(result)
                                .listRowSeparator(.hidden)
                                .listRowInsets(.init(top: 4, leading: 0, bottom: 4, trailing: 0))
                                .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .listRowSpacing(0)
                }
            } else if filteredPodcasts.isEmpty {
                if trimmedSearchText.isEmpty, selectedScope == .subscribed {
                    PodcastsEmptyView()
                } else if trimmedSearchText.isEmpty {
                    ContentUnavailableView(
                        selectedScope == .unsubscribed ? "No Unsubscribed Podcasts" : "No Podcasts",
                        systemImage: selectedScope == .unsubscribed ? "pause.circle" : "dot.radiowaves.left.and.right",
                        description: Text(selectedScope == .unsubscribed ? "Podcasts kept in the database but excluded from refresh will appear here." : "No podcasts are stored in the library yet.")
                    )
                } else {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("No podcasts matched \"\(searchText)\".")
                    )
                }
            } else {
                List {

      
                    NavigationLink(destination: AllEpisodesListView()) {
                        HStack {
                            Text("All Episodes")
                                .font(.headline)

                        }
                    }
      
                    
                    // The clickable header using NavigationLink
                    NavigationLink(destination: AllEpisodesListView().onlyPlayed()) {
                        HStack {
                            Text("Recently Played Episodes")
                                .font(.headline)

                        }
                    }
                
                NavigationLink(destination: DownloadedEpisodesView()) {
                    HStack {
                        Text("Downloaded Episodes")
                            .font(.headline)

                    }
                }
                
              
                
                NavigationLink(destination: BookmarkListView()) {
                    HStack {
                        Text("All Bookmarks")
                            .font(.headline)

                    }
                }
                NavigationLink(destination: PlaySessionDebugView()) {
                    HStack {
                        Text("Listening History")
                            .font(.headline)

                    }
                }
                
                ForEach(filteredPodcasts) { podcast in
                    ZStack {
                        PodcastRowView(podcast: podcast)
                       //     .id(episode.url)
                        NavigationLink(destination: PodcastDetailView(podcast: podcast)) {
                            EmptyView()
                        }.opacity(0)
                    }
                    
                    .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0,
                                                 leading: 0,
                                                 bottom: 0,
                                                 trailing: 0))
                }
                .onDelete { indexSet in
                    Task {
                        for index in indexSet {
                            await viewModel.deletePodcast(filteredPodcasts[index])
                        }
                    }
                }
                }
                .animation(.easeInOut, value: filteredPodcasts.map(\.persistentModelID))
                .listStyle(.plain)
                .listRowSpacing(0)
            }
        }
        .navigationTitle("Library")
        .searchable(text: $searchText, prompt: "Search podcasts")
        .task {
            applyFilters()
        }
        .onChange(of: searchText) { _, _ in
            scheduleSearchUpdate()
        }
        .onChange(of: searchInTitle) { _, _ in
            scheduleSearchUpdate()
        }
        .onChange(of: searchInAuthor) { _, _ in
            scheduleSearchUpdate()
        }
        .onChange(of: searchInDescription) { _, _ in
            scheduleSearchUpdate()
        }
        .onChange(of: searchInEpisodes) { _, _ in
            scheduleSearchUpdate()
        }
        .onChange(of: podcasts.map { "\($0.persistentModelID)-\($0.isSubscribed)" }) { _, _ in
            scheduleSearchUpdate()
        }
        .onChange(of: selectedScope) { _, _ in
            scheduleSearchUpdate()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Podcast Scope", selection: $selectedScope) {
                        ForEach(LibraryScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                } label: {
                    Image(systemName: selectedScope == .unsubscribed ? "pause.circle" : "line.3.horizontal.decrease.circle")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Titles", isOn: $searchInTitle)
                    Toggle("Authors", isOn: $searchInAuthor)
                    Toggle("Descriptions", isOn: $searchInDescription)
                    Toggle("Episodes", isOn: $searchInEpisodes)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await viewModel.refreshAllPodcasts() }
                } label: {
                    if viewModel.isLoading {
                        if viewModel.total != 0 {
                            CircularProgressView(
                                value: Double(viewModel.completed),
                                total: Double(viewModel.total)
                            )
                        } else {
                            ProgressView()
                        }
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isLoading)
            }
        }
    }

    private func scheduleSearchUpdate() {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            // Keep typing responsive while coalescing rapid keystrokes.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard Task.isCancelled == false else { return }
            applyFilters()
        }
    }

    private func applyFilters() {
        let currentPodcasts = podcasts.filter { podcast in
            switch selectedScope {
            case .subscribed:
                return podcast.isSubscribed
            case .unsubscribed:
                return podcast.isSubscribed == false
            case .all:
                return true
            }
        }
        let query = trimmedSearchText

        guard query.isEmpty == false else {
            filteredPodcasts = currentPodcasts
            episodeSearchResults = []
            return
        }

        if searchInEpisodes {
            var results: [EpisodeSearchResult] = []

            for podcast in currentPodcasts {
                let sortedEpisodes = (podcast.episodes ?? [])
                    .sorted(by: { ($0.publishDate ?? .distantPast) > ($1.publishDate ?? .distantPast) })
                for episode in sortedEpisodes {
                    if let match = episodeSearchMatch(for: episode, query: query) {
                        results.append(match)
                    }
                }
            }

            episodeSearchResults = results
            filteredPodcasts = []
            return
        }

        filteredPodcasts = currentPodcasts.filter { podcast in
            if searchInTitle, podcast.title.localizedStandardContains(query) {
                return true
            }
            if searchInAuthor, let author = podcast.author, author.localizedStandardContains(query) {
                return true
            }
            if searchInDescription, let desc = podcast.desc, desc.localizedStandardContains(query) {
                return true
            }
            if searchInEpisodes, let episodes = podcast.episodes {
                if episodes.contains(where: { $0.title.localizedStandardContains(query) }) {
                    return true
                }
                if searchInDescription,
                   episodes.contains(where: { $0.desc?.localizedStandardContains(query) == true }) {
                    return true
                }
            }

            return false
        }
        episodeSearchResults = []
    }

    private func episodeSearchMatch(for episode: Episode, query: String) -> EpisodeSearchResult? {
        let normalizedQuery = query.lowercased()

        if searchInDescription {
            if let desc = episode.desc, desc.lowercased().contains(normalizedQuery) {
                return EpisodeSearchResult(
                    episode: episode,
                    kind: .showNotes,
                    snippet: snippet(from: desc, query: query)
                )
            }
            if let subtitle = episode.subtitle, subtitle.lowercased().contains(normalizedQuery) {
                return EpisodeSearchResult(
                    episode: episode,
                    kind: .showNotes,
                    snippet: snippet(from: subtitle, query: query)
                )
            }
            if let content = episode.content, content.lowercased().contains(normalizedQuery) {
                return EpisodeSearchResult(
                    episode: episode,
                    kind: .showNotes,
                    snippet: snippet(from: content, query: query)
                )
            }
        }

        if episode.title.lowercased().contains(normalizedQuery) {
            return EpisodeSearchResult(
                episode: episode,
                kind: .title,
                snippet: snippet(from: episode.title, query: query)
            )
        }

        if let transcriptLines = episode.transcriptLines, transcriptLines.isEmpty == false {
            for line in transcriptLines {
                if line.text.lowercased().contains(normalizedQuery) {
                    return EpisodeSearchResult(
                        episode: episode,
                        kind: .transcript(startTime: line.startTime),
                        snippet: line.text
                    )
                }
            }
        }

        return nil
    }

    private func snippet(from text: String, query: String, maxLength: Int = 140) -> String {
        let cleanedText = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanedText.count > maxLength else { return cleanedText }

        let lowercaseText = cleanedText.lowercased()
        let lowercaseQuery = query.lowercased()
        if let range = lowercaseText.range(of: lowercaseQuery) {
            let lowerBound = cleanedText.distance(from: cleanedText.startIndex, to: range.lowerBound)
            let startOffset = max(0, lowerBound - (maxLength / 2))
            let startIndex = cleanedText.index(cleanedText.startIndex, offsetBy: startOffset)
            let endIndex = cleanedText.index(startIndex, offsetBy: min(maxLength, cleanedText.distance(from: startIndex, to: cleanedText.endIndex)))
            let clipped = String(cleanedText[startIndex..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            return startOffset == 0 ? clipped : "…\(clipped)"
        }

        return String(cleanedText.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func episodeResultRow(_ result: EpisodeSearchResult) -> some View {
        let episode = result.episode
        ZStack {
            CoverImageView(podcast: episode.podcast)
                .scaledToFill()
                .frame(maxWidth: .infinity, minHeight: 124, maxHeight: 124)
                .blur(radius: 8)
                .clipped()

            HStack(alignment: .top, spacing: 12) {
                CoverImageView(episode: episode)
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let podcastTitle = episode.podcast?.title, podcastTitle.isEmpty == false {
                            Text(podcastTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Text(episode.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        Text(result.kind.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(result.snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                if case .transcript(let startTime) = result.kind, let episodeURL = episode.url {
                    Button {
                        Task {
                            await Player.shared.playEpisode(episodeURL, playDirectly: true, startingAt: startTime)
                        }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass(.clear))
                    .accessibilityLabel("Play from \(Duration.seconds(startTime).formatted(.units(width: .abbreviated)))")
                }
            }
            .padding(8)
            .background(Rectangle().fill(.thinMaterial))
        }
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
    }
}

private struct EpisodeSearchResult: Identifiable {
    enum MatchKind {
        case title
        case showNotes
        case transcript(startTime: Double)

        var label: String {
            switch self {
            case .title:
                return "Matched in title"
            case .showNotes:
                return "Matched in show notes"
            case .transcript(let startTime):
                return "Matched in transcript at \(Duration.seconds(startTime).formatted(.units(width: .abbreviated)))"
            }
        }
    }

    let id: String
    let episode: Episode
    let kind: MatchKind
    let snippet: String

    init(episode: Episode, kind: MatchKind, snippet: String) {
        self.episode = episode
        self.kind = kind
        self.snippet = snippet
        self.id = "\(episode.persistentModelID)-\(kind.idSuffix)"
    }
}

private extension EpisodeSearchResult.MatchKind {
    var idSuffix: String {
        switch self {
        case .title:
            return "title"
        case .showNotes:
            return "shownotes"
        case .transcript(let startTime):
            return "transcript-\(Int(startTime * 10))"
        }
    }
}



#Preview {
    PodcastListView(modelContainer: try! ModelContainer(for: Podcast.self, Episode.self))
} 
