//  PodcastCategoryView.swift
//  Raul
//
//  Podcast category browsing backed by the Apple Podcasts genre tree.
//

import SwiftUI
import SwiftData

struct PodcastCategoryView: View {
    @StateObject private var viewModel: CategoryPodcastViewModel
    @Environment(\.modelContext) private var context

    init(genres: [AppleGenre] = [], title: String? = nil) {
        _viewModel = StateObject(wrappedValue: CategoryPodcastViewModel(genres: genres, title: title))
    }

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 16)]

    var body: some View {
        Group {
            if viewModel.isRoot && viewModel.genres.isEmpty {
                if viewModel.isLoading {
                    ProgressView("Loading categories...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        ContentUnavailableView(
                            "Categories Unavailable",
                            systemImage: "square.grid.2x2",
                            description: Text(viewModel.errorMessage ?? "Couldn’t load podcast categories.")
                        )
                        Button("Try Again") { viewModel.loadIfNeeded(forceReload: true) }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(viewModel.genres) { genre in
                            if genre.hasSubgenres {
                                NavigationLink {
                                    PodcastCategoryView(genres: genre.subgenres, title: genre.name)
                                } label: {
                                    CategoryCard(genre: genre)
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink {
                                    PodcastCategoryViewLeaf(genre: genre)
                                } label: {
                                    CategoryCard(genre: genre)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(viewModel.navigationTitle)
        .onAppear {
            viewModel.loadIfNeeded()
        }
    }
}

// A genre card with its SF Symbol over the genre name, used in the grid.
private struct CategoryCard: View {
    let genre: AppleGenre

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: genre.symbolName)
                .font(.system(size: 30))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(height: 38)

            Text(genre.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// Shows the top podcasts for a leaf genre (one without subgenres).
private struct PodcastCategoryViewLeaf: View {
    @StateObject private var viewModel: CategoryPodcastViewModel
    @Environment(\.modelContext) private var context
    @Query private var allPodcasts: [Podcast]
    @State private var subscriptionLookup = PodcastDiscoverySubscriptionLookup(podcasts: [])

    init(genre: AppleGenre) {
        _viewModel = StateObject(wrappedValue: CategoryPodcastViewModel(genres: [], selectedGenre: genre))
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.podcasts.isEmpty {
                ProgressView("Loading podcasts...")
            } else if viewModel.podcasts.isEmpty {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        "No Podcasts Found",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text(viewModel.errorMessage ?? "The chart is empty or unavailable right now.")
                    )
                    Button("Try Again") { viewModel.loadPodcastsForSelectedGenre(forceReload: true) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(viewModel.podcasts, id: \.self) { podcast in
                        SubscribeToPodcastView(newPodcastFeed: podcast, existingPodcast: existingPodcast(for: podcast))
                            .modelContext(context)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(viewModel.selectedGenre?.name ?? "Podcasts")
        .onAppear {
            viewModel.loadPodcastsForSelectedGenre()
        }
        .task {
            subscriptionLookup = PodcastDiscoverySubscriptionLookup(podcasts: allPodcasts)
        }
        .onChange(of: allPodcasts.map(PodcastDiscoverySubscriptionLookup.signature(for:))) {
            subscriptionLookup = PodcastDiscoverySubscriptionLookup(podcasts: allPodcasts)
        }
    }

    private func existingPodcast(for feed: PodcastFeed) -> Podcast? {
        subscriptionLookup.existingPodcast(for: feed, context: context)
    }
}

@MainActor
final class CategoryPodcastViewModel: ObservableObject {
    @Published var genres: [AppleGenre]
    @Published var podcasts: [PodcastFeed] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    let isRoot: Bool
    let selectedGenre: AppleGenre?
    private let title: String?
    private var didLoadPodcasts = false
    private var requestGeneration = 0
    private let iTunesActor = ITunesSearchActor()

    var hasSubgenres: Bool { !genres.isEmpty }

    var navigationTitle: String {
        if let title {
            return title
        } else if isRoot {
            return "Categories"
        } else if let selectedGenre {
            return selectedGenre.name
        } else {
            return "Podcasts"
        }
    }

    init(genres: [AppleGenre] = [], selectedGenre: AppleGenre? = nil, title: String? = nil) {
        self.genres = genres
        self.selectedGenre = selectedGenre
        self.title = title
        self.isRoot = genres.isEmpty && selectedGenre == nil
    }

    func loadIfNeeded(forceReload: Bool = false) {
        guard isRoot, isLoading == false, forceReload || genres.isEmpty else { return }
        requestGeneration &+= 1
        let generation = requestGeneration
        isLoading = true
        errorMessage = nil
        Task {
            let fetched = await iTunesActor.getGenres()
            guard generation == requestGeneration else { return }
            self.genres = fetched
            self.isLoading = false
            if fetched.isEmpty {
                self.errorMessage = "Couldn’t load podcast categories. Check your connection and try again."
            }
        }
    }

    func loadPodcastsForSelectedGenre(forceReload: Bool = false) {
        guard let genre = selectedGenre,
              isLoading == false,
              forceReload || didLoadPodcasts == false else { return }
        requestGeneration &+= 1
        let generation = requestGeneration
        didLoadPodcasts = true
        isLoading = true
        errorMessage = nil
        Task {
            let fetched = await iTunesActor.getTopPodcasts(genreID: genre.id, limit: 50)
            guard generation == requestGeneration else { return }
            self.podcasts = fetched
            self.isLoading = false
            if fetched.isEmpty {
                self.didLoadPodcasts = false
                self.errorMessage = "Couldn’t load this chart or it has no results. Check your connection and try again."
            }
        }
    }
}

#Preview {
    NavigationStack {
        PodcastCategoryView()
    }
}
