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
    @State private var selectedScope: LibraryScope = .subscribed

    init(modelContainer: ModelContainer) {
        _viewModel = StateObject(wrappedValue: PodcastListViewModel(modelContainer: modelContainer))
    }

    private var podcastsInScope: [Podcast] {
        podcasts.filter { podcast in
            switch selectedScope {
            case .subscribed:
                return podcast.isSubscribed
            case .unsubscribed:
                return podcast.isSubscribed == false
            case .all:
                return true
            }
        }
    }

    var body: some View {
        Group {
            if podcastsInScope.isEmpty {
                if selectedScope == .subscribed {
                    PodcastsEmptyView()
                } else {
                    ContentUnavailableView(
                        selectedScope == .unsubscribed ? "No Unsubscribed Podcasts" : "No Podcasts",
                        systemImage: selectedScope == .unsubscribed ? "pause.circle" : "dot.radiowaves.left.and.right",
                        description: Text(selectedScope == .unsubscribed ? "Podcasts kept in the database but excluded from refresh will appear here." : "No podcasts are stored in the library yet.")
                    )
                }
            } else {
                List {
                    
                    NavigationLink(destination: LibrarySearchView()) {
                        HStack {
                            Text("Search Library")
                                .font(.headline)
                        }
                    }

                    NavigationLink(destination: AllEpisodesListView()) {
                        HStack {
                            Text("All Episodes")
                                .font(.headline)
                        }
                    }

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

                    ForEach(podcastsInScope) { podcast in
                        ZStack {
                            PodcastRowView(podcast: podcast)
                            NavigationLink(destination: PodcastDetailView(podcast: podcast)) {
                                EmptyView()
                            }.opacity(0)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open podcast \(podcast.title)")
                        .accessibilityHint("Opens this podcast details screen")
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
                                await viewModel.deletePodcast(podcastsInScope[index])
                            }
                        }
                    }
                }
                .animation(.easeInOut, value: podcastsInScope.map(\.persistentModelID))
                .listStyle(.plain)
                .listRowSpacing(0)
            }
        }
        .navigationTitle("Library")
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
                .accessibilityHint("Filter library by subscribed, not subscribed, or all podcasts")
                .accessibilityInputLabels([Text("Podcast scope"), Text("Library scope")])
            }

            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(destination: LibrarySearchView()) {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search library")
                .accessibilityHint("Search podcasts, episodes, chapters, and transcripts")
                .accessibilityInputLabels([Text("Search library"), Text("Library search")])
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
                .accessibilityLabel(viewModel.isLoading ? "Refreshing podcasts" : "Refresh podcasts")
                .accessibilityHint("Updates all podcast feeds in your library")
                .accessibilityInputLabels([Text("Refresh podcasts"), Text("Refresh library")])
            }
        }
    }
}

#Preview {
    PodcastListView(modelContainer: try! ModelContainer(for: Podcast.self, Episode.self))
}
