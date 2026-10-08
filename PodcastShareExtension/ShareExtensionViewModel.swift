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
    @Published var selectedPlaylistID: UUID?

    private var extensionContext: NSExtensionContext?
    private var sharedURL: URL?
    private var didComplete = false
    private var isActive = true

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
        guard isActive, didComplete == false, let podcast = podcastFeed, let sharedURL else { return }
        ShareExtensionDiagnostics.log("action.subscribe")
        state = .saving
        do {
            try PendingSharedEpisodeShareStore.save(.subscribe(feedURL: podcast.feedURL, sharedURL: sharedURL))
            state = .saved("The podcast will open in Up Next so you can subscribe.")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func search() {
        guard isActive, didComplete == false, let sharedURL, let query = searchQuery else { return }
        ShareExtensionDiagnostics.log("action.search")
        state = .saving
        do {
            try PendingSharedEpisodeShareStore.save(.search(query: query, sharedURL: sharedURL))
            state = .saved("Up Next will open Add with \(query) prefilled.")
        } catch {
            state = .failed(error.localizedDescription)
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
        ShareExtensionDiagnostics.log("handling.stopped")
    }

    private var searchQuery: String? {
        switch state {
        case .unresolved(_, let query): return query ?? sharedHost
        case .podcast(let podcast): return podcast.title
        default: return sharedHost
        }
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
