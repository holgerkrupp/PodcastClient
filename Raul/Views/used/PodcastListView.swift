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
    @State private var selectedScope: LibraryScope = .subscribed
    @State private var searchText = ""
    @State private var searchInTitle = true
    @State private var searchInAuthor = false
    @State private var searchInDescription = true
    @State private var searchInEpisodes = true

    init(modelContainer: ModelContainer) {
        _viewModel = StateObject(wrappedValue: PodcastListViewModel(modelContainer: modelContainer))
    }

    var body: some View {
        Group {
            if filteredPodcasts.isEmpty {
                if searchText.isEmpty, selectedScope == .subscribed {
                    PodcastsEmptyView()
                } else if searchText.isEmpty {
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
                       //     .id(episode.id)
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
            debounceFilters()
        }
        .onChange(of: searchInTitle) { _, _ in
            applyFilters()
        }
        .onChange(of: searchInAuthor) { _, _ in
            applyFilters()
        }
        .onChange(of: searchInDescription) { _, _ in
            applyFilters()
        }
        .onChange(of: searchInEpisodes) { _, _ in
            applyFilters()
        }
        .onChange(of: podcasts.map { "\($0.persistentModelID)-\($0.isSubscribed)" }) { _, _ in
            applyFilters()
        }
        .onChange(of: selectedScope) { _, _ in
            applyFilters()
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

    private func debounceFilters() {
        Debounce.shared.perform {
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
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard query.isEmpty == false else {
            filteredPodcasts = currentPodcasts
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
    }
}



#Preview {
    PodcastListView(modelContainer: try! ModelContainer(for: Podcast.self, Episode.self))
} 
