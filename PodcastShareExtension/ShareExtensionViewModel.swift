import Combine
import Foundation

@MainActor
final class ShareExtensionViewModel: ObservableObject {
    enum State: Equatable {
        case loading
        case checking(URL)
        case podcastEpisode(ShareLinkPodcast, ShareLinkEpisode)
        case podcast(ShareLinkPodcast)
        case standalone(ShareLinkStandaloneMedia)
        case unresolved(URL, String?)
        case saving
        case saved(String)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var playlists: [SharedEpisodePlaylistSnapshot] = []
    @Published private(set) var podcastFeed: ShareLinkPodcast?
    @Published private(set) var searchResults: [ShareLinkPodcast] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasSearched = false
    @Published private(set) var searchError: String?
    @Published var selectedPlaylistID: UUID?
    @Published var searchQuery = ""

    private var extensionContext: NSExtensionContext?
    private var sharedURL: URL?
    private var didComplete = false
    private var isActive = true
    private var searchTask: Task<Void, Never>?

    var canAdd: Bool {
        switch state {
        case .podcastEpisode, .standalone: return true
        default: return false
        }
    }

    var canSearch: Bool {
        switch state {
        case .unresolved, .podcast: return true
        default: return false
        }
    }

    var canSubscribe: Bool { isActive && didComplete == false && podcastFeed != nil && sharedURL != nil }

    var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    var sharedHost: String? { sharedURL?.host() }

    func prepare(extensionContext: NSExtensionContext?) async {
        guard isActive, didComplete == false, state == .loading, Task.isCancelled == false else { return }
        ShareExtensionDiagnostics.log("prepare.started")
        guard let extensionContext else {
            ShareExtensionDiagnostics.log("prepare.missingContext")
            state = .failed(ShareExtensionError.missingExtensionContext.localizedDescription)
            return
        }
        self.extensionContext = extensionContext
        let url = await SharedURLExtractor.firstURL(in: extensionContext.inputItems)
        guard isActive, didComplete == false, Task.isCancelled == false else {
            ShareExtensionDiagnostics.log("prepare.abandonedAfterExtraction")
            return
        }
        guard let url else {
            ShareExtensionDiagnostics.log("prepare.noURL")
            state = .failed(ShareExtensionError.noURL.localizedDescription)
            return
        }

        sharedURL = url
        playlists = PendingSharedEpisodeShareStore.playlists()
        state = .checking(url)
        ShareExtensionDiagnostics.log("url.extracted")
        let resolution = await ShareLinkResolver().resolve(url) { [weak self] podcast in
            guard let self, self.isActive, self.didComplete == false else { return }
            self.podcastFeed = podcast
            ShareExtensionDiagnostics.log("podcast.feedFound")
        }
        guard isActive, didComplete == false, Task.isCancelled == false else {
            ShareExtensionDiagnostics.log("prepare.abandonedAfterResolution")
            return
        }
        guard case .checking = state else { return }
        podcastFeed = resolution.podcastFeed ?? podcastFeed
        state = resolution.state
        switch resolution {
        case .unresolved(_, let query, _): searchQuery = query ?? url.host() ?? ""
        case .podcast(let podcast): searchQuery = podcast.title
        default: break
        }
        ShareExtensionDiagnostics.log("url.ready")
    }

    func addEpisode() {
        guard isActive, didComplete == false, canAdd, let sharedURL else { return }
        ShareExtensionDiagnostics.log("action.add")
        state = .saving
        do {
            try PendingSharedEpisodeShareStore.save(.importEpisode(url: sharedURL, playlistID: selectedPlaylistID))
            state = .saved(destinationDescription)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func subscribe() {
        guard let podcast = podcastFeed else { return }
        subscribe(to: podcast)
    }

    func subscribe(to podcast: ShareLinkPodcast) {
        guard isActive, didComplete == false, let sharedURL else { return }
        ShareExtensionDiagnostics.log("action.subscribe")
        state = .saving
        do {
            try PendingSharedEpisodeShareStore.save(.subscribe(feedURL: podcast.feedURL, sharedURL: sharedURL))
            state = .saved("Up Next will subscribe to the podcast when it opens.")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func search() {
        guard isActive, didComplete == false else { return }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return }

        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            self.isSearching = true
            self.hasSearched = true
            self.searchError = nil
            self.searchResults = []

            do {
                let results = try await SharePodcastSearchService().search(query)
                guard self.isActive, self.didComplete == false, Task.isCancelled == false else { return }
                self.searchResults = results
            } catch is CancellationError {
                return
            } catch {
                guard self.isActive, self.didComplete == false else { return }
                self.searchError = "Couldn’t search podcasts. Check your connection and try again."
            }
            self.isSearching = false
        }
    }

    func done() {
        ShareExtensionDiagnostics.log("action.done")
        completeOnce()
    }

    func cancel() {
        ShareExtensionDiagnostics.log("action.cancel")
        completeOnce()
    }

    func stopHandling() {
        guard isActive else { return }
        isActive = false
        searchTask?.cancel()
        ShareExtensionDiagnostics.log("handling.stopped")
    }

    private var destinationDescription: String {
        guard let selectedPlaylistID, let playlist = playlists.first(where: { $0.id == selectedPlaylistID }) else {
            return "The episode will appear in Inbox."
        }
        return "The episode will appear in \(playlist.title)."
    }

    private func completeOnce() {
        guard didComplete == false else {
            ShareExtensionDiagnostics.log("completion.duplicateIgnored")
            return
        }
        didComplete = true
        isActive = false
        ShareExtensionDiagnostics.log("completion.requested")
        extensionContext?.completeRequest(returningItems: nil)
    }
}

private struct SharePodcastSearchService: Sendable {
    private struct SearchResponse: Decodable {
        let results: [Result]
    }

    private struct Result: Decodable {
        let collectionName: String?
        let artistName: String?
        let feedUrl: URL?
        let artworkUrl600: URL?
        let artworkUrl100: URL?
    }

    func search(_ query: String) async throws -> [ShareLinkPodcast] {
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "country", value: Locale.autoupdatingCurrent.region?.identifier.lowercased() ?? "us"),
            URLQueryItem(name: "limit", value: "25")
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let responseBody = try JSONDecoder().decode(SearchResponse.self, from: data)
        return responseBody.results.compactMap { result in
            guard let feedURL = result.feedUrl,
                  let title = result.collectionName,
                  title.isEmpty == false else { return nil }
            return ShareLinkPodcast(
                title: title,
                feedURL: feedURL,
                artworkURL: result.artworkUrl600 ?? result.artworkUrl100,
                author: result.artistName
            )
        }
    }
}

private extension ShareLinkResolution {
    var state: ShareExtensionViewModel.State {
        switch self {
        case .podcastEpisode(let podcast, let episode): return .podcastEpisode(podcast, episode)
        case .podcast(let podcast): return .podcast(podcast)
        case .standaloneMedia(let media, _): return .standalone(media)
        case .unresolved(let url, let query, _): return .unresolved(url, query)
        }
    }
}
