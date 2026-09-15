//
//  PublicBroadcasterSearchView.swift
//  Raul
//
//  Cross-provider search. Every searchable broadcaster is queried concurrently;
//  a provider that fails simply contributes nothing.
//

import SwiftUI
import SwiftData

struct PublicBroadcasterSearchView: View {
    @Environment(\.modelContext) private var context
    @StateObject private var viewModel: PublicBroadcasterSearchViewModel

    init(registry: PodcastDiscoveryRegistry = .shared) {
        _viewModel = StateObject(wrappedValue: PublicBroadcasterSearchViewModel(registry: registry))
    }

    var body: some View {
        List {
            Section {
                TextField("Search Public Broadcasters", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .listRowSeparator(.hidden)
            }

            if viewModel.isSearching {
                HStack {
                    Spacer()
                    ProgressView()
                        .accessibilityLabel("Loading")
                    Spacer()
                }
                .listRowSeparator(.hidden)
            } else if viewModel.hasQuery, viewModel.results.isEmpty {
                Text("No podcasts found")
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(viewModel.results) { podcast in
                    NavigationLink {
                        DiscoveredPodcastBrowseView(podcast: podcast)
                            .modelContext(context)
                    } label: {
                        DiscoveredPodcastRowView(
                            podcast: podcast,
                            showsSource: true,
                            registry: viewModel.registry
                        )
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Search Public Broadcasters")
    }
}

@MainActor
final class PublicBroadcasterSearchViewModel: ObservableObject {
    @Published var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleSearch()
        }
    }
    @Published private(set) var results: [DiscoveredPodcast] = []
    @Published private(set) var isSearching = false

    let registry: PodcastDiscoveryRegistry

    private let service: PodcastDiscoveryService
    private var searchTask: Task<Void, Never>?

    var hasQuery: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    init(registry: PodcastDiscoveryRegistry = .shared) {
        self.registry = registry
        self.service = PodcastDiscoveryService(registry: registry)
    }

    private func scheduleSearch() {
        searchTask?.cancel()

        let query = searchText
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            results = []
            isSearching = false
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard Task.isCancelled == false else { return }
            await self?.runSearch(for: query)
        }
    }

    private func runSearch(for query: String) async {
        isSearching = true
        defer { isSearching = false }

        let found = await service.search(query)
        guard Task.isCancelled == false, searchText == query else { return }
        results = found
    }
}
