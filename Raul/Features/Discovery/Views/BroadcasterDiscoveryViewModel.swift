//
//  BroadcasterDiscoveryViewModel.swift
//  Raul
//
//  View state for one broadcaster. Results are kept per mode so switching back
//  and forth does not refetch, and every provider failure becomes the same
//  neutral "currently unavailable" state — endpoints never reach the UI.
//

import Foundation
import SwiftUI

@MainActor
final class BroadcasterDiscoveryViewModel: ObservableObject {
    @Published var mode: PodcastDiscoveryBrowseMode
    @Published var podcasts: [DiscoveredPodcast] = []
    @Published var categories: [PodcastDiscoveryCategory] = []
    @Published var searchResults: [DiscoveredPodcast] = []
    @Published var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleSearch()
        }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var isSearching = false
    @Published private(set) var hasFailed = false

    let modes: [PodcastDiscoveryBrowseMode]

    private let provider: any PodcastDiscoveryProvider
    private var loadedModes: Set<PodcastDiscoveryBrowseMode> = []
    private var searchTask: Task<Void, Never>?
    private var podcastsByMode: [PodcastDiscoveryBrowseMode: [DiscoveredPodcast]] = [:]

    init(provider: any PodcastDiscoveryProvider) {
        self.provider = provider
        let modes = provider.capabilities.browseModes
        self.modes = modes
        self.mode = modes.first ?? .search
    }

    func loadCurrentModeIfNeeded() async {
        guard loadedModes.contains(mode) == false else {
            podcasts = podcastsByMode[mode] ?? []
            return
        }
        await load(mode: mode, refresh: false)
    }

    func reloadCurrentMode() async {
        if mode == .search {
            await runSearch(for: searchText)
            return
        }
        await load(mode: mode, refresh: true)
    }

    private func load(mode: PodcastDiscoveryBrowseMode, refresh: Bool) async {
        guard mode != .search else { return }

        isLoading = true
        hasFailed = false
        podcasts = podcastsByMode[mode] ?? []

        defer { isLoading = false }

        do {
            switch mode {
            case .featured:
                let result = try await provider.featured(refresh: refresh)
                podcastsByMode[mode] = result
                if self.mode == mode { podcasts = result }
            case .allPodcasts, .publisherCatalog:
                let result = try await provider.allPodcasts(refresh: refresh)
                podcastsByMode[mode] = result
                if self.mode == mode { podcasts = result }
            case .categories:
                categories = try await provider.categories(refresh: refresh)
            case .search:
                return
            }

            loadedModes.insert(mode)
        } catch is CancellationError {
            // Navigating away is not a failure.
        } catch {
            hasFailed = true
        }
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()

        let query = searchText
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            searchResults = []
            isSearching = false
            return
        }

        searchTask = Task { [weak self] in
            // Debounce so a fast typist does not fire a request per keystroke.
            try? await Task.sleep(for: .milliseconds(350))
            guard Task.isCancelled == false else { return }
            await self?.runSearch(for: query)
        }
    }

    private func runSearch(for query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            searchResults = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            let results = try await provider.search(trimmed)
            guard Task.isCancelled == false, searchText == query else { return }
            searchResults = results
        } catch is CancellationError {
            return
        } catch {
            guard searchText == query else { return }
            searchResults = []
        }
    }
}

@MainActor
final class BroadcasterCategoryViewModel: ObservableObject {
    @Published private(set) var podcasts: [DiscoveredPodcast] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasFailed = false

    private let provider: any PodcastDiscoveryProvider
    private let category: PodcastDiscoveryCategory
    private var didLoad = false

    init(provider: any PodcastDiscoveryProvider, category: PodcastDiscoveryCategory) {
        self.provider = provider
        self.category = category
    }

    func load(refresh: Bool) async {
        guard refresh || didLoad == false else { return }
        didLoad = true
        isLoading = true
        hasFailed = false

        defer { isLoading = false }

        do {
            podcasts = try await provider.podcasts(in: category, refresh: refresh)
        } catch is CancellationError {
            return
        } catch {
            hasFailed = true
        }
    }
}
