import SwiftUI
import SwiftData
import ESADesignKit

struct LibrarySearchView: View {
    enum LibraryScope: String, CaseIterable, Identifiable, Sendable {
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

    @State private var groupedResults: [PodcastSearchResultGroup] = []
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
                                            PodcastSearchResultRow(
                                                result: result,
                                                artworkSize: resultArtworkSize,
                                                rowHeight: resultRowHeight
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(.init(top: 2, leading: 0, bottom: 2, trailing: 0))
                                        .listRowBackground(Color.clear)

                                    case .episode(let result):
                                        EpisodeSearchResultRow(
                                            result: result,
                                            artworkSize: resultArtworkSize,
                                            rowHeight: resultRowHeight
                                        )
                                            .listRowSeparator(.hidden)
                                            .listRowInsets(.init(top: 2, leading: 0, bottom: 2, trailing: 0))
                                            .listRowBackground(Color.clear)
                                    }
                                }
                            },
                            label: {
                                PodcastSearchGroupHeader(
                                    group: group,
                                    artworkSize: groupArtworkSize,
                                    rowHeight: groupHeaderHeight
                                )
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
            ToolbarItem(placement: .primaryAction) {
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

            ToolbarItem(placement: .primaryAction) {
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

    private struct PodcastSearchGroupHeader: View {
        let group: PodcastSearchResultGroup
        let artworkSize: CGFloat
        let rowHeight: CGFloat

        var body: some View {
            HStack(spacing: 14) {
                CoverImageView(imageURL: group.podcast.imageURL)
                    .frame(width: artworkSize, height: artworkSize)
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
            .ESA_RowView(image: group.podcast.imageURL, minHeight: rowHeight)
        }
    }

    private struct PodcastSearchResultRow: View {
        let result: PodcastSearchResult
        let artworkSize: CGFloat
        let rowHeight: CGFloat

        var body: some View {
            HStack(spacing: 12) {
                CoverImageView(imageURL: result.podcast.imageURL)
                    .frame(width: artworkSize, height: artworkSize)
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
            .ESA_RowView(image: result.podcast.imageURL, minHeight: rowHeight)
        }
    }

    private struct EpisodeSearchResultRow: View {
        let result: EpisodeSearchResult
        let artworkSize: CGFloat
        let rowHeight: CGFloat

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                CoverImageView(imageURL: result.episodeImageURL ?? result.podcast.imageURL)
                    .frame(width: artworkSize, height: artworkSize)
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
            .ESA_RowView(image: result.podcast.imageURL, minHeight: rowHeight)
        }
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
            await runSearch(query: query, generation: generation)
        }
    }

    @MainActor
    private func clearResults() {
        groupedResults = []
        expandedPodcastGroupIDs = []
        isSearching = false
        searchError = nil
    }

    @MainActor
    private func runSearch(query: String, generation: Int) async {
        let scope: LibrarySearchRequest.Scope = switch selectedScope {
        case .subscribed: .subscribed
        case .unsubscribed: .unsubscribed
        case .all: .all
        }
        let request = LibrarySearchRequest(
            query: query,
            scope: scope,
            searchInTitle: searchInTitle,
            searchInAuthor: searchInAuthor,
            searchInDescription: searchInDescription,
            searchInEpisodes: searchInEpisodes,
            minimumCharactersForTranscriptSearch: minimumCharactersForTranscriptSearch
        )

        do {
            let searchActor = LibrarySearchActor(modelContainer: modelContext.container)
            let groups = try await searchActor.search(request: request)
            guard Task.isCancelled == false else { return }
            guard generation == searchGeneration else { return }

            groupedResults = groups
            syncExpandedGroups(with: groups)
            isSearching = false
            searchError = nil
        } catch {
            guard Task.isCancelled == false else { return }
            guard generation == searchGeneration else { return }
            groupedResults = []
            expandedPodcastGroupIDs = []
            isSearching = false
            searchError = error.localizedDescription
        }
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

}

struct PodcastSearchResult: Identifiable, Sendable {
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

struct SearchScopeFilter: Sendable {
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

struct EpisodeSearchResult: Identifiable, Sendable {
    enum MatchKind: Sendable {
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

struct PodcastGroupSummary: Identifiable, Sendable {
    let podcastID: PersistentIdentifier
    let title: String
    let author: String?
    let desc: String?
    let imageURL: URL?

    var id: String { "\(podcastID)" }
}

struct PodcastSearchResultGroup: Identifiable, Sendable {
    let podcast: PodcastGroupSummary
    let items: [GroupedSearchItem]

    var id: String { podcast.id }

    var resultCountLabel: String {
        let count = items.count
        return count == 1 ? "1 result" : "\(count) results"
    }
}

enum GroupedSearchItem: Identifiable, Sendable {
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
