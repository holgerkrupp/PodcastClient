import SwiftUI
import SwiftData

struct LibrarySearchView: View {
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

    @Environment(\.modelContext) private var modelContext

    @State private var searchText = ""
    @State private var selectedScope: LibraryScope = .subscribed
    @State private var searchInTitle = true
    @State private var searchInAuthor = false
    @State private var searchInDescription = true
    @State private var searchInEpisodes = true

    @State private var podcastResults: [PodcastSearchResult] = []
    @State private var episodeResults: [EpisodeSearchResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchGeneration: Int = 0
    @State private var expandedPodcastGroupIDs: Set<String> = []

    @ScaledMetric(relativeTo: .body) private var groupHeaderHeight: CGFloat = 128
    @ScaledMetric(relativeTo: .body) private var groupArtworkSize: CGFloat = 96
    @ScaledMetric(relativeTo: .body) private var resultRowHeight: CGFloat = 132
    @ScaledMetric(relativeTo: .body) private var resultArtworkSize: CGFloat = 82

    private let minimumCharactersForTranscriptSearch = 3

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var groupedResults: [PodcastSearchResultGroup] {
        var groupedItems: [String: [GroupedSearchItem]] = [:]
        var groupedPodcast: [String: PodcastGroupSummary] = [:]

        for result in podcastResults {
            groupedItems[result.podcastKey, default: []].append(.podcast(result))
            groupedPodcast[result.podcastKey] = result.podcast
        }

        for result in episodeResults {
            groupedItems[result.podcastKey, default: []].append(.episode(result))
            groupedPodcast[result.podcastKey] = result.podcast
        }

        return groupedItems.compactMap { key, items in
            guard let podcast = groupedPodcast[key] else { return nil }
            let sortedItems = items.sorted(by: GroupedSearchItem.sortOrder)
            return PodcastSearchResultGroup(podcast: podcast, items: sortedItems)
        }
        .sorted { lhs, rhs in
            lhs.podcast.title.localizedCaseInsensitiveCompare(rhs.podcast.title) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if trimmedSearchText.isEmpty {
                ContentUnavailableView(
                    "Search Your Library",
                    systemImage: "magnifyingglass",
                    description: Text("Search podcasts, episodes, chapters, and transcripts directly in SwiftData.")
                )
            } else if groupedResults.isEmpty {
                if isSearching {
                    ProgressView("Searching Library...")
                } else if let searchError {
                    ContentUnavailableView(
                        "Search Failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(searchError)
                    )
                } else {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("No matches found for \"\(trimmedSearchText)\".")
                    )
                }
            } else {
                List {
                    ForEach(groupedResults) { group in
                        DisclosureGroup(
                            isExpanded: expandedBinding(for: group.id),
                            content: {
                                ForEach(group.items) { item in
                                    switch item {
                                    case .podcast(let result):
                                        NavigationLink(destination: PodcastSearchDestinationView(podcastID: result.podcast.podcastID)) {
                                            podcastMatchRow(result)
                                        }
                                        .buttonStyle(.plain)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(.init(top: 2, leading: 0, bottom: 2, trailing: 0))
                                        .listRowBackground(Color.clear)

                                    case .episode(let result):
                                        episodeMatchRow(result)
                                            .listRowSeparator(.hidden)
                                            .listRowInsets(.init(top: 2, leading: 0, bottom: 2, trailing: 0))
                                            .listRowBackground(Color.clear)
                                    }
                                }
                            },
                            label: {
                                podcastGroupHeader(group)
                            }
                        )
                        .listRowSeparator(.hidden)
                        .listRowInsets(.init(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                    }

                    if isSearching {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Updating search results...")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .listRowBackground(Color.clear)
                    }

                    if searchInEpisodes,
                       trimmedSearchText.count > 0,
                       trimmedSearchText.count < minimumCharactersForTranscriptSearch {
                        Text("Use at least \(minimumCharactersForTranscriptSearch) characters to search transcripts.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .listRowSpacing(0)
            }
        }
        .navigationTitle("Library Search")
        .searchable(text: $searchText, prompt: "Search library")
        .task {
            scheduleSearch(immediate: true)
        }
        .onChange(of: searchText) { _, _ in
            scheduleSearch()
        }
        .onChange(of: selectedScope) { _, _ in
            scheduleSearch(immediate: true)
        }
        .onChange(of: searchInTitle) { _, _ in
            scheduleSearch(immediate: true)
        }
        .onChange(of: searchInAuthor) { _, _ in
            scheduleSearch(immediate: true)
        }
        .onChange(of: searchInDescription) { _, _ in
            scheduleSearch(immediate: true)
        }
        .onChange(of: searchInEpisodes) { _, _ in
            scheduleSearch(immediate: true)
        }
        .onDisappear {
            searchTask?.cancel()
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
                .accessibilityLabel("Podcast scope")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Titles", isOn: $searchInTitle)
                    Toggle("Authors", isOn: $searchInAuthor)
                    Toggle("Descriptions", isOn: $searchInDescription)
                    Toggle("Episodes", isOn: $searchInEpisodes)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Search filters")
            }
        }
    }

    @ViewBuilder
    private func podcastGroupHeader(_ group: PodcastSearchResultGroup) -> some View {
        ZStack {
            CoverImageView(imageURL: group.podcast.imageURL)
                .scaledToFill()
                .frame(maxWidth: .infinity, minHeight: groupHeaderHeight, maxHeight: groupHeaderHeight)
                .blur(radius: 8)
                .opacity(0.45)
                .clipped()
                .accessibilityHidden(true)

            HStack(spacing: 14) {
                CoverImageView(imageURL: group.podcast.imageURL)
                    .frame(width: groupArtworkSize, height: groupArtworkSize)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(group.podcast.title)
                        .font(.headline)
                        .lineLimit(2)

                    if let author = group.podcast.author, author.isEmpty == false {
                        Text(author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(group.resultCountLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: groupHeaderHeight, alignment: .leading)
            .background(
                Rectangle()
                    .fill(.thinMaterial)
            )
        }
        .frame(maxWidth: .infinity, minHeight: groupHeaderHeight, alignment: .leading)
    }

    @ViewBuilder
    private func podcastMatchRow(_ result: PodcastSearchResult) -> some View {
        ZStack {
            CoverImageView(imageURL: result.podcast.imageURL)
                .scaledToFill()
                .frame(maxWidth: .infinity, minHeight: resultRowHeight, maxHeight: resultRowHeight)
                .blur(radius: 8)
                .opacity(0.45)
                .clipped()
                .accessibilityHidden(true)

            HStack(spacing: 12) {
                CoverImageView(imageURL: result.podcast.imageURL)
                    .frame(width: resultArtworkSize, height: resultArtworkSize)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(result.title)
                        .font(.headline)
                        .lineLimit(2)

                    if let author = result.author, author.isEmpty == false {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text("Matched in podcast metadata")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if let snippet = result.snippet, snippet.isEmpty == false {
                        Text(snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: resultRowHeight, alignment: .leading)
            .background(
                Rectangle()
                    .fill(.thinMaterial)
            )
        }
        .frame(maxWidth: .infinity, minHeight: resultRowHeight, alignment: .leading)
    }

    @ViewBuilder
    private func episodeMatchRow(_ result: EpisodeSearchResult) -> some View {
        ZStack {
            CoverImageView(imageURL: result.podcast.imageURL)
                .scaledToFill()
                .frame(maxWidth: .infinity, minHeight: resultRowHeight, maxHeight: resultRowHeight)
                .blur(radius: 8)
                .opacity(0.45)
                .clipped()
                .accessibilityHidden(true)

            HStack(alignment: .top, spacing: 12) {
                CoverImageView(imageURL: result.episodeImageURL ?? result.podcast.imageURL)
                    .frame(width: resultArtworkSize, height: resultArtworkSize)
                    .accessibilityHidden(true)

                NavigationLink(destination: EpisodeSearchDestinationView(episodeID: result.episodeID)) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(result.episodeTitle)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if let startTime = result.kind.transcriptStartTime,
                   let episodeURL = result.episodeURL {
                    Button {
                        Task {
                            await Player.shared.playEpisode(
                                episodeURL,
                                playDirectly: true,
                                startingAt: startTime
                            )
                        }
                    } label: {
                        Label("Play from transcript match", systemImage: "play.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .background(.thinMaterial, in: Circle())
                    .accessibilityLabel("Play from \(Duration.seconds(startTime).formatted(.units(width: .abbreviated)))")
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: resultRowHeight, alignment: .topLeading)
            .background(
                Rectangle()
                    .fill(.thinMaterial)
            )
        }
        .frame(maxWidth: .infinity, minHeight: resultRowHeight, alignment: .leading)
    }

    private func expandedBinding(for groupID: String) -> Binding<Bool> {
        Binding(
            get: { expandedPodcastGroupIDs.contains(groupID) },
            set: { isExpanded in
                if isExpanded {
                    expandedPodcastGroupIDs.insert(groupID)
                } else {
                    expandedPodcastGroupIDs.remove(groupID)
                }
            }
        )
    }

    private func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()

        let query = trimmedSearchText
        guard query.isEmpty == false else {
            searchGeneration += 1
            clearResults()
            return
        }

        isSearching = true
        searchError = nil
        searchGeneration += 1
        let generation = searchGeneration
        let delayNanos: UInt64 = immediate ? 0 : 180_000_000

        searchTask = Task {
            if delayNanos > 0 {
                try? await Task.sleep(nanoseconds: delayNanos)
            }
            guard Task.isCancelled == false else { return }
            runSearch(query: query, generation: generation)
        }
    }

    @MainActor
    private func clearResults() {
        podcastResults = []
        episodeResults = []
        expandedPodcastGroupIDs = []
        isSearching = false
        searchError = nil
    }

    @MainActor
    private func runSearch(query: String, generation: Int) {
        do {
            let searchContext = ModelContext(modelContext.container)
            let scopeFilter = try buildScopeFilter(in: searchContext)
            let podcasts = try fetchPodcastResults(query: query, in: searchContext, scopeFilter: scopeFilter)
            guard Task.isCancelled == false else { return }
            let episodes = try fetchEpisodeResults(query: query, in: searchContext, scopeFilter: scopeFilter)
            guard Task.isCancelled == false else { return }
            guard generation == searchGeneration else { return }

            podcastResults = podcasts
            episodeResults = episodes
            syncExpandedGroups(with: groupedResults)
            isSearching = false
            searchError = nil
        } catch {
            guard generation == searchGeneration else { return }
            podcastResults = []
            episodeResults = []
            expandedPodcastGroupIDs = []
            isSearching = false
            searchError = error.localizedDescription
        }
    }

    @MainActor
    private func fetchPodcastResults(
        query: String,
        in context: ModelContext,
        scopeFilter: SearchScopeFilter
    ) throws -> [PodcastSearchResult] {
        var matchesByID: [String: PodcastSearchResult] = [:]

        func insertUnique(_ podcasts: [Podcast]) {
            for podcast in podcasts {
                let podcastID = podcast.persistentModelID
                let key = "\(podcastID)"
                guard scopeFilter.includesPodcast(id: key) else { continue }
                if matchesByID[key] == nil {
                    guard let podcast = scopeFilter.podcastSummary(forPodcastID: key) else { continue }
                    matchesByID[key] = PodcastSearchResult(
                        podcast: podcast,
                        title: podcast.title,
                        author: podcast.author,
                        snippet: podcast.desc.map { snippet(from: $0, query: query) }
                    )
                }
            }
        }

        if searchInTitle {
            let titlePredicate = podcastTitlePredicate(query: query)
            var descriptor = FetchDescriptor<Podcast>(
                predicate: titlePredicate,
                sortBy: [SortDescriptor(\Podcast.title)]
            )
            descriptor.fetchLimit = 300
            insertUnique(try context.fetch(descriptor))
        }

        if searchInAuthor {
            let authorPredicate = podcastAuthorPredicate(query: query)
            var descriptor = FetchDescriptor<Podcast>(
                predicate: authorPredicate,
                sortBy: [SortDescriptor(\Podcast.title)]
            )
            descriptor.fetchLimit = 300
            insertUnique(try context.fetch(descriptor))
        }

        if searchInDescription {
            let descriptionPredicate = podcastDescriptionPredicate(query: query)
            var descriptor = FetchDescriptor<Podcast>(
                predicate: descriptionPredicate,
                sortBy: [SortDescriptor(\Podcast.title)]
            )
            descriptor.fetchLimit = 300
            insertUnique(try context.fetch(descriptor))
        }

        return matchesByID
            .values
            .sorted { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    @MainActor
    private func fetchEpisodeResults(
        query: String,
        in context: ModelContext,
        scopeFilter: SearchScopeFilter
    ) throws -> [EpisodeSearchResult] {
        guard searchInEpisodes else { return [] }

        var matchesByEpisodeID: [String: EpisodeSearchResult] = [:]

        func insertIfNeeded(episode: Episode, kind: EpisodeSearchResult.MatchKind, snippet: String) {
            let episodeID = episode.persistentModelID
            let key = "\(episodeID)"
            guard scopeFilter.includesEpisode(id: key) else { return }
            guard matchesByEpisodeID[key] == nil else { return }
            guard let podcastID = scopeFilter.podcastID(forEpisodeID: key) else { return }
            guard let podcast = scopeFilter.podcastSummary(forPodcastID: podcastID) else { return }
            matchesByEpisodeID[key] = EpisodeSearchResult(
                podcast: podcast,
                episodeID: episodeID,
                episodeTitle: episode.title,
                publishDate: episode.publishDate,
                episodeURL: episode.url,
                episodeImageURL: episode.imageURL,
                kind: kind,
                snippet: snippet
            )
        }

        if searchInTitle {
            let titlePredicate = episodeTitlePredicate(query: query)
            var descriptor = FetchDescriptor<Episode>(
                predicate: titlePredicate,
                sortBy: [SortDescriptor(\Episode.publishDate, order: .reverse)]
            )
            descriptor.fetchLimit = 500
            let matches = try context.fetch(descriptor)
            for episode in matches {
                insertIfNeeded(
                    episode: episode,
                    kind: .title,
                    snippet: snippet(from: episode.title, query: query)
                )
            }
        }

        if searchInAuthor {
            let authorPredicate = episodeAuthorPredicate(query: query)
            var descriptor = FetchDescriptor<Episode>(
                predicate: authorPredicate,
                sortBy: [SortDescriptor(\Episode.publishDate, order: .reverse)]
            )
            descriptor.fetchLimit = 500
            let matches = try context.fetch(descriptor)
            for episode in matches {
                let authorText = episode.author ?? ""
                insertIfNeeded(
                    episode: episode,
                    kind: .author,
                    snippet: snippet(from: authorText, query: query)
                )
            }
        }

        if searchInDescription {
            var descriptionDescriptor = FetchDescriptor<Episode>(
                predicate: episodeDescPredicate(query: query),
                sortBy: [SortDescriptor(\Episode.publishDate, order: .reverse)]
            )
            descriptionDescriptor.fetchLimit = 500
            let descriptionMatches = try context.fetch(descriptionDescriptor)
            for episode in descriptionMatches {
                if let desc = episode.desc, containsIgnoringCaseAndDiacritics(desc, query: query) {
                    insertIfNeeded(
                        episode: episode,
                        kind: .showNotes,
                        snippet: snippet(from: desc, query: query)
                    )
                }
            }

            var subtitleDescriptor = FetchDescriptor<Episode>(
                predicate: episodeSubtitlePredicate(query: query),
                sortBy: [SortDescriptor(\Episode.publishDate, order: .reverse)]
            )
            subtitleDescriptor.fetchLimit = 500
            let subtitleMatches = try context.fetch(subtitleDescriptor)
            for episode in subtitleMatches {
                if let subtitle = episode.subtitle, containsIgnoringCaseAndDiacritics(subtitle, query: query) {
                    insertIfNeeded(
                        episode: episode,
                        kind: .showNotes,
                        snippet: snippet(from: subtitle, query: query)
                    )
                }
            }

            var contentDescriptor = FetchDescriptor<Episode>(
                predicate: episodeContentPredicate(query: query),
                sortBy: [SortDescriptor(\Episode.publishDate, order: .reverse)]
            )
            contentDescriptor.fetchLimit = 500
            let contentMatches = try context.fetch(contentDescriptor)
            for episode in contentMatches {
                if let content = episode.content, containsIgnoringCaseAndDiacritics(content, query: query) {
                    insertIfNeeded(
                        episode: episode,
                        kind: .showNotes,
                        snippet: snippet(from: content, query: query)
                    )
                }
            }
        }

        let chapterPredicate = chapterTitlePredicate(query: query)
        var chapterDescriptor = FetchDescriptor<Marker>(predicate: chapterPredicate)
        chapterDescriptor.fetchLimit = 600
        let chapterMatches = try context.fetch(chapterDescriptor)

        for chapter in chapterMatches {
            guard let episode = chapter.episode else { continue }
            insertIfNeeded(
                episode: episode,
                kind: .chapter(startTime: chapter.start ?? 0),
                snippet: snippet(from: chapter.title, query: query)
            )
        }

        if query.count >= minimumCharactersForTranscriptSearch {
            let transcriptPredicate = transcriptLinePredicate(query: query)
            var transcriptDescriptor = FetchDescriptor<TranscriptLineAndTime>(
                predicate: transcriptPredicate,
                sortBy: [SortDescriptor(\TranscriptLineAndTime.startTime)]
            )
            transcriptDescriptor.fetchLimit = 1_500
            let transcriptMatches = try context.fetch(transcriptDescriptor)

            for line in transcriptMatches {
                guard let episode = line.episode else { continue }
                insertIfNeeded(
                    episode: episode,
                    kind: .transcript(startTime: line.startTime),
                    snippet: snippet(from: line.text, query: query, maxLength: 180)
                )
            }
        }

        return matchesByEpisodeID
            .values
            .sorted { lhs, rhs in
                let leftDate = lhs.publishDate ?? .distantPast
                let rightDate = rhs.publishDate ?? .distantPast
                if leftDate != rightDate {
                    return leftDate > rightDate
                }
                return lhs.episodeTitle.localizedCaseInsensitiveCompare(rhs.episodeTitle) == .orderedAscending
            }
    }

    private func buildScopeFilter(in context: ModelContext) throws -> SearchScopeFilter {
        let descriptor: FetchDescriptor<Podcast>
        switch selectedScope {
        case .all:
            descriptor = FetchDescriptor<Podcast>()
        case .subscribed:
            descriptor = FetchDescriptor<Podcast>(
                predicate: #Predicate<Podcast> { podcast in
                    podcast.metaData?.isSubscribed != false
                }
            )
        case .unsubscribed:
            descriptor = FetchDescriptor<Podcast>(
                predicate: #Predicate<Podcast> { podcast in
                    podcast.metaData?.isSubscribed == false
                }
            )
        }

        let scopedPodcasts = try context.fetch(descriptor)

        var podcastIDs = Set<String>()
        var episodeIDs = Set<String>()
        var podcastSummaries: [String: PodcastGroupSummary] = [:]
        var episodeToPodcastID: [String: String] = [:]

        for podcast in scopedPodcasts {
            let podcastID = podcast.persistentModelID
            let podcastKey = "\(podcastID)"
            podcastIDs.insert(podcastKey)
            podcastSummaries[podcastKey] = PodcastGroupSummary(
                podcastID: podcastID,
                title: podcast.title,
                author: podcast.author,
                desc: podcast.desc,
                imageURL: podcast.imageURL
            )
            for episode in podcast.episodes ?? [] {
                let episodeKey = "\(episode.persistentModelID)"
                episodeIDs.insert(episodeKey)
                episodeToPodcastID[episodeKey] = podcastKey
            }
        }

        return SearchScopeFilter(
            podcastIDs: podcastIDs,
            episodeIDs: episodeIDs,
            podcastsByID: podcastSummaries,
            episodeToPodcastID: episodeToPodcastID
        )
    }

    private func syncExpandedGroups(with groups: [PodcastSearchResultGroup]) {
        let ids = Set(groups.map(\.id))
        if ids.isEmpty {
            expandedPodcastGroupIDs = []
            return
        }

        let preserved = expandedPodcastGroupIDs.intersection(ids)
        expandedPodcastGroupIDs = preserved.isEmpty ? ids : preserved
    }

    private func podcastTitlePredicate(query: String) -> Predicate<Podcast> {
        #Predicate<Podcast> { podcast in
            podcast.title.localizedStandardContains(query)
        }
    }

    private func podcastAuthorPredicate(query: String) -> Predicate<Podcast> {
        #Predicate<Podcast> { podcast in
            podcast.author?.localizedStandardContains(query) == true
        }
    }

    private func podcastDescriptionPredicate(query: String) -> Predicate<Podcast> {
        #Predicate<Podcast> { podcast in
            podcast.desc?.localizedStandardContains(query) == true
        }
    }

    private func episodeTitlePredicate(query: String) -> Predicate<Episode> {
        #Predicate<Episode> { episode in
            episode.title.localizedStandardContains(query)
        }
    }

    private func episodeAuthorPredicate(query: String) -> Predicate<Episode> {
        #Predicate<Episode> { episode in
            episode.author?.localizedStandardContains(query) == true
        }
    }

    private func episodeDescPredicate(query: String) -> Predicate<Episode> {
        #Predicate<Episode> { episode in
            episode.desc?.localizedStandardContains(query) == true
        }
    }

    private func episodeSubtitlePredicate(query: String) -> Predicate<Episode> {
        #Predicate<Episode> { episode in
            episode.subtitle?.localizedStandardContains(query) == true
        }
    }

    private func episodeContentPredicate(query: String) -> Predicate<Episode> {
        #Predicate<Episode> { episode in
            episode.content?.localizedStandardContains(query) == true
        }
    }

    private func chapterTitlePredicate(query: String) -> Predicate<Marker> {
        #Predicate<Marker> { chapter in
            chapter.title.localizedStandardContains(query)
        }
    }

    private func transcriptLinePredicate(query: String) -> Predicate<TranscriptLineAndTime> {
        #Predicate<TranscriptLineAndTime> { line in
            line.text.localizedStandardContains(query)
        }
    }

    private func containsIgnoringCaseAndDiacritics(_ text: String, query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: .current) != nil
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
}

private struct PodcastSearchResult: Identifiable {
    let id: String
    let podcast: PodcastGroupSummary
    let title: String
    let author: String?
    let snippet: String?
    var podcastKey: String { "\(podcast.podcastID)" }

    init(podcast: PodcastGroupSummary, title: String, author: String?, snippet: String?) {
        self.id = "\(podcast.podcastID)-podcast-match"
        self.podcast = podcast
        self.title = title
        self.author = author
        self.snippet = snippet
    }
}

private struct SearchScopeFilter {
    let podcastIDs: Set<String>
    let episodeIDs: Set<String>
    let podcastsByID: [String: PodcastGroupSummary]
    let episodeToPodcastID: [String: String]

    func podcastSummary(forPodcastID id: String) -> PodcastGroupSummary? {
        podcastsByID[id]
    }

    func podcastID(forEpisodeID id: String) -> String? {
        episodeToPodcastID[id]
    }

    func includesPodcast(id: String) -> Bool {
        podcastIDs.contains(id)
    }

    func includesEpisode(id: String) -> Bool {
        episodeIDs.contains(id)
    }
}

private struct EpisodeSearchResult: Identifiable {
    enum MatchKind {
        case title
        case author
        case showNotes
        case chapter(startTime: Double)
        case transcript(startTime: Double)

        var label: String {
            switch self {
            case .title:
                return "Matched in title"
            case .author:
                return "Matched in author"
            case .showNotes:
                return "Matched in show notes"
            case .chapter(let startTime):
                return "Matched in chapter at \(Duration.seconds(startTime).formatted(.units(width: .abbreviated)))"
            case .transcript(let startTime):
                return "Matched in transcript at \(Duration.seconds(startTime).formatted(.units(width: .abbreviated)))"
            }
        }

        var idSuffix: String {
            switch self {
            case .title:
                return "title"
            case .author:
                return "author"
            case .showNotes:
                return "shownotes"
            case .chapter(let startTime):
                return "chapter-\(Int(startTime * 10))"
            case .transcript(let startTime):
                return "transcript-\(Int(startTime * 10))"
            }
        }

        var transcriptStartTime: Double? {
            switch self {
            case .transcript(let startTime):
                return startTime
            case .title, .author, .showNotes, .chapter:
                return nil
            }
        }
    }

    let id: String
    let podcast: PodcastGroupSummary
    let episodeID: PersistentIdentifier
    let episodeTitle: String
    let publishDate: Date?
    let episodeURL: URL?
    let episodeImageURL: URL?
    let kind: MatchKind
    let snippet: String
    var podcastKey: String { "\(podcast.podcastID)" }

    init(
        podcast: PodcastGroupSummary,
        episodeID: PersistentIdentifier,
        episodeTitle: String,
        publishDate: Date?,
        episodeURL: URL?,
        episodeImageURL: URL?,
        kind: MatchKind,
        snippet: String
    ) {
        self.podcast = podcast
        self.episodeID = episodeID
        self.episodeTitle = episodeTitle
        self.publishDate = publishDate
        self.episodeURL = episodeURL
        self.episodeImageURL = episodeImageURL
        self.kind = kind
        self.snippet = snippet
        self.id = "\(episodeID)-\(kind.idSuffix)"
    }
}

private struct PodcastGroupSummary: Identifiable {
    let podcastID: PersistentIdentifier
    let title: String
    let author: String?
    let desc: String?
    let imageURL: URL?

    var id: String { "\(podcastID)" }
}

private struct PodcastSearchResultGroup: Identifiable {
    let podcast: PodcastGroupSummary
    let items: [GroupedSearchItem]

    var id: String { podcast.id }

    var resultCountLabel: String {
        let count = items.count
        return count == 1 ? "1 result" : "\(count) results"
    }
}

private enum GroupedSearchItem: Identifiable {
    case podcast(PodcastSearchResult)
    case episode(EpisodeSearchResult)

    var id: String {
        switch self {
        case .podcast(let result):
            return result.id
        case .episode(let result):
            return result.id
        }
    }

    var sortWeight: Int {
        switch self {
        case .podcast:
            return 0
        case .episode:
            return 1
        }
    }

    var publishDate: Date? {
        switch self {
        case .podcast:
            return nil
        case .episode(let result):
            return result.publishDate
        }
    }

    var title: String {
        switch self {
        case .podcast(let result):
            return result.title
        case .episode(let result):
            return result.episodeTitle
        }
    }

    static func sortOrder(_ lhs: GroupedSearchItem, _ rhs: GroupedSearchItem) -> Bool {
        if lhs.sortWeight != rhs.sortWeight {
            return lhs.sortWeight < rhs.sortWeight
        }

        let leftDate = lhs.publishDate ?? .distantPast
        let rightDate = rhs.publishDate ?? .distantPast
        if leftDate != rightDate {
            return leftDate > rightDate
        }

        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}

private struct PodcastSearchDestinationView: View {
    @Environment(\.modelContext) private var modelContext
    let podcastID: PersistentIdentifier

    var body: some View {
        if let podcast = modelContext.model(for: podcastID) as? Podcast {
            PodcastDetailView(podcast: podcast)
        } else {
            ContentUnavailableView(
                "Podcast Unavailable",
                systemImage: "trash",
                description: Text("This podcast could not be loaded.")
            )
        }
    }
}

private struct EpisodeSearchDestinationView: View {
    @Environment(\.modelContext) private var modelContext
    let episodeID: PersistentIdentifier

    var body: some View {
        if let episode = modelContext.model(for: episodeID) as? Episode {
            EpisodeDetailView(episode: episode)
        } else {
            ContentUnavailableView(
                "Episode Unavailable",
                systemImage: "trash",
                description: Text("This episode could not be loaded.")
            )
        }
    }
}

#Preview {
    NavigationStack {
        LibrarySearchView()
    }
}
