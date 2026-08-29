//  PodcastCategoryView.swift
//  Raul
//
//  Podcast category browsing backed by the Apple Podcasts genre tree.
//

import SwiftUI

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
                ProgressView("Loading categories...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    init(genre: AppleGenre) {
        _viewModel = StateObject(wrappedValue: CategoryPodcastViewModel(genres: [], selectedGenre: genre))
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.podcasts.isEmpty {
                ProgressView("Loading podcasts...")
            } else if viewModel.podcasts.isEmpty {
                Text("No podcasts found")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                List {
                    ForEach(viewModel.podcasts, id: \.self) { podcast in
                        SubscribeToPodcastView(newPodcastFeed: podcast)
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
    }
}

@MainActor
final class CategoryPodcastViewModel: ObservableObject {
    @Published var genres: [AppleGenre]
    @Published var podcasts: [PodcastFeed] = []
    @Published var isLoading = false

    let isRoot: Bool
    let selectedGenre: AppleGenre?
    private let title: String?
    private var didLoadPodcasts = false
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

    func loadIfNeeded() {
        guard isRoot, genres.isEmpty else { return }
        Task {
            let fetched = await iTunesActor.getGenres()
            self.genres = fetched
        }
    }

    func loadPodcastsForSelectedGenre() {
        guard let genre = selectedGenre, didLoadPodcasts == false else { return }
        didLoadPodcasts = true
        isLoading = true
        Task {
            let fetched = await iTunesActor.getTopPodcasts(genreID: genre.id, limit: 50)
            self.podcasts = fetched
            self.isLoading = false
        }
    }
}

#Preview {
    NavigationStack {
        PodcastCategoryView()
    }
}
