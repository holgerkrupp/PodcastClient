//
//  BroadcasterDiscoveryView.swift
//  Raul
//
//  Browses one broadcaster. The available browse modes come from the provider's
//  capabilities, so a search-only provider shows a search field and nothing
//  else — no empty controls for the sake of symmetry.
//

import SwiftUI
import SwiftData

struct BroadcasterDiscoveryView: View {
    @Environment(\.modelContext) private var context
    @StateObject private var viewModel: BroadcasterDiscoveryViewModel

    private let provider: any PodcastDiscoveryProvider

    init(provider: any PodcastDiscoveryProvider) {
        self.provider = provider
        _viewModel = StateObject(wrappedValue: BroadcasterDiscoveryViewModel(provider: provider))
    }

    var body: some View {
        Group {
            if viewModel.modes.isEmpty {
                BroadcasterUnavailableView(broadcaster: provider.broadcaster)
            } else {
                content
            }
        }
        .navigationTitle(provider.broadcaster.name)
        .task {
            await viewModel.loadCurrentModeIfNeeded()
        }
    }

    @ViewBuilder
    private var content: some View {
        List {
            if viewModel.modes.count > 1 {
                Section {
                    Picker("Browse", selection: $viewModel.mode) {
                        ForEach(viewModel.modes) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                }
            }

            switch viewModel.mode {
            case .categories:
                categorySection
            case .search:
                searchSection
            case .featured, .allPodcasts, .publisherCatalog:
                podcastSection(viewModel.podcasts)
            }

            if let attribution = provider.attribution {
                Text(attribution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .refreshable {
            await viewModel.reloadCurrentMode()
        }
        .onChange(of: viewModel.mode) {
            Task { await viewModel.loadCurrentModeIfNeeded() }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var categorySection: some View {
        if viewModel.isLoading && viewModel.categories.isEmpty {
            loadingRow
        } else if viewModel.hasFailed && viewModel.categories.isEmpty {
            unavailableRow
        } else {
            ForEach(viewModel.categories) { category in
                NavigationLink {
                    BroadcasterCategoryPodcastsView(provider: provider, category: category)
                        .modelContext(context)
                } label: {
                    HStack {
                        Text(category.title)
                        if let count = category.podcastCount {
                            Spacer()
                            Text("\(count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("\(count) podcasts")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        Section {
            TextField("Search", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .listRowSeparator(.hidden)
                .accessibilityLabel("Search Public Broadcasters")
        }

        if viewModel.isSearching {
            loadingRow
        } else if viewModel.searchText.isEmpty == false, viewModel.searchResults.isEmpty {
            Text("No podcasts found")
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        } else {
            podcastRows(viewModel.searchResults)
        }
    }

    @ViewBuilder
    private func podcastSection(_ podcasts: [DiscoveredPodcast]) -> some View {
        if viewModel.isLoading && podcasts.isEmpty {
            loadingRow
        } else if viewModel.hasFailed && podcasts.isEmpty {
            unavailableRow
        } else if podcasts.isEmpty {
            Text("No podcasts found")
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        } else {
            podcastRows(podcasts)
        }
    }

    @ViewBuilder
    private func podcastRows(_ podcasts: [DiscoveredPodcast]) -> some View {
        ForEach(podcasts) { podcast in
            NavigationLink {
                DiscoveredPodcastBrowseView(podcast: podcast)
                    .modelContext(context)
            } label: {
                DiscoveredPodcastRowView(podcast: podcast)
            }
        }
    }

    private var loadingRow: some View {
        HStack {
            Spacer()
            ProgressView()
                .accessibilityLabel("Loading")
            Spacer()
        }
        .listRowSeparator(.hidden)
    }

    private var unavailableRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(provider.broadcaster.summary)
                .font(.subheadline)
            Text("Currently unavailable. Try again later.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
    }
}

/// Podcasts inside one provider category.
struct BroadcasterCategoryPodcastsView: View {
    @Environment(\.modelContext) private var context
    @StateObject private var viewModel: BroadcasterCategoryViewModel

    private let category: PodcastDiscoveryCategory

    init(provider: any PodcastDiscoveryProvider, category: PodcastDiscoveryCategory) {
        self.category = category
        _viewModel = StateObject(
            wrappedValue: BroadcasterCategoryViewModel(provider: provider, category: category)
        )
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.podcasts.isEmpty {
                ProgressView()
                    .accessibilityLabel("Loading")
            } else if viewModel.hasFailed && viewModel.podcasts.isEmpty {
                Text("Currently unavailable. Try again later.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else if viewModel.podcasts.isEmpty {
                Text("No podcasts found")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List(viewModel.podcasts) { podcast in
                    NavigationLink {
                        DiscoveredPodcastBrowseView(podcast: podcast)
                            .modelContext(context)
                    } label: {
                        DiscoveredPodcastRowView(podcast: podcast)
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await viewModel.load(refresh: true)
                }
            }
        }
        .navigationTitle(category.title)
        .task {
            await viewModel.load(refresh: false)
        }
    }
}
