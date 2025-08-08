//  PodcastCategoryView.swift
//  Raul
//
//  Created for podcast category browsing using FyydSearchManager.
//

import SwiftUI
import fyyd_swift

struct PodcastCategoryView: View {
    @StateObject private var viewModel: CategoryPodcastViewModel
    @Environment(\.modelContext) private var context

    init(categories: [FyydCategory] = []) {
        _viewModel = StateObject(wrappedValue: CategoryPodcastViewModel(categories: categories))
    }

    var body: some View {
        List{
          
                if viewModel.isRoot && viewModel.categories.isEmpty {
                    ProgressView("Loading categories...")
                        .padding()
                } else if !viewModel.hasSubcategories {
                    if viewModel.isLoading {
                        ProgressView("Loading podcasts...")
                    } else if viewModel.podcasts.isEmpty {
                        Text("No podcasts found")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(viewModel.podcasts, id: \.id) { podcast in
                            SubscribeToPodcastView(fyydPodcastFeed: podcast)
                                .modelContext(context)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(.init(top: 0, leading: 0, bottom: 1, trailing: 0))
                        }
                        
                    }
                } else {
                    ForEach(viewModel.categories, id: \.self) { category in
                        if let subs = category.subcategories, !subs.isEmpty {
                            NavigationLink{
                                PodcastCategoryView(categories: category.subcategories ?? [])
                            } label: {
                                HStack{
                                    Text(category.name)
                                        .font(.headline)
                                }
                            }
                        } else {
                            NavigationLink {
                                PodcastCategoryViewLeaf(category: category)
                            } label: {
                                HStack{
                                    Text(category.name)
                                        .font(.headline)
                                }}
                        }
                    }
                    
                }
            
        }
        .listStyle(.plain)
        .navigationTitle(viewModel.navigationTitle)

        .onAppear {
            viewModel.loadIfNeeded()
        }
    }
}

// A separate view to show podcasts for leaf categories (no subcategories)
private struct PodcastCategoryViewLeaf: View {
    @StateObject private var viewModel: CategoryPodcastViewModel
    @Environment(\.modelContext) private var context

    init(category: FyydCategory) {
        _viewModel = StateObject(wrappedValue: CategoryPodcastViewModel(categories: [], selectedCategory: category))
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
                    ForEach(viewModel.podcasts, id: \.id) { podcast in
                        SubscribeToPodcastView(fyydPodcastFeed: podcast)
                            .modelContext(context)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0, leading: 0, bottom: 1, trailing: 0))
                            .onAppear {
                                if podcast == viewModel.podcasts.last,
                                   let nextPage = viewModel.paging?.next_page,
                                   !viewModel.isLoadingPage {
                                    viewModel.loadPodcastsForSelectedCategory(loadNextPage: true)
                                }
                            }
                    }
                    if viewModel.isLoadingPage && viewModel.paging?.next_page != nil {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(viewModel.selectedCategory?.name ?? "Podcasts")
        .onAppear {
            viewModel.loadPodcastsForSelectedCategory()
        }
    }
}

@MainActor
final class CategoryPodcastViewModel: ObservableObject {
    @Published var categories: [FyydCategory]
    @Published var podcasts: [FyydPodcast] = []
    @Published var isLoading = false
    
    @Published var paging: PagingInfo? = nil
    private var currentPage: Int = 0
    public var isLoadingPage = false

    let isRoot: Bool
    var selectedCategory: FyydCategory?
    var hasSubcategories: Bool { !categories.isEmpty }
    private let fyydManager = FyydSearchManager()

    var navigationTitle: String {
        if isRoot {
            return "Categories"
        } else if let selected = selectedCategory {
            return selected.name
        } else if !categories.isEmpty {
            return "Subcategories"
        } else {
            return "Podcasts"
        }
    }

    // Root or subcategory list
    init(categories: [FyydCategory] = [], selectedCategory: FyydCategory? = nil) {
        self.categories = categories
        self.selectedCategory = selectedCategory
        self.isRoot = categories.isEmpty && selectedCategory == nil
    }

    func loadIfNeeded() {
        if isRoot {
            Task {
                let fetched = await fyydManager.getCategories() ?? []
                await MainActor.run {
                    self.categories = fetched
                }
            }
        } else if selectedCategory != nil && categories.isEmpty {
            // leaf category case handled by PodcastCategoryViewLeaf
        }
    }

    /// Loads podcasts for the selected category.
    /// - Parameter loadNextPage: If true, loads the next page of results and appends them to the existing list.
    ///   If false (default), loads the first page and replaces the podcast list.
    func loadPodcastsForSelectedCategory(loadNextPage: Bool = false) {
        guard let category = selectedCategory else { return }
        if isLoadingPage { return }
        isLoadingPage = true
        isLoading = !loadNextPage
        let nextPage = loadNextPage ? ((paging?.next_page) ?? (currentPage + 1)) : 0
        Task {
            let result = await fyydManager.getPodcastsByCategory(id: category.id, count: 30, page: nextPage)
            await MainActor.run {
                if let result = result {
                    if loadNextPage {
                        self.podcasts.append(contentsOf: result.podcasts)
                    } else {
                        self.podcasts = result.podcasts
                    }
                    self.paging = result.paging
                    self.currentPage = nextPage
                }
                self.isLoading = false
                self.isLoadingPage = false
            }
        }
    }
}

#Preview {
    NavigationStack {
        PodcastCategoryView()
    }
}
