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
    @Published var selectedPlaylistID: UUID?

    private var extensionContext: NSExtensionContext?
    private var sharedURL: URL?
    private var didComplete = false

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

    var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    var sharedHost: String? { sharedURL?.host() }

    func prepare(extensionContext: NSExtensionContext?) async {
        guard state == .loading else { return }
        guard let extensionContext else {
            state = .failed(ShareExtensionError.missingExtensionContext.localizedDescription)
            return
        }
        guard let url = await SharedURLExtractor.firstURL(in: extensionContext.inputItems) else {
            state = .failed(ShareExtensionError.noURL.localizedDescription)
            return
        }

        self.extensionContext = extensionContext
        sharedURL = url
        playlists = PendingSharedEpisodeShareStore.playlists()
        state = .checking(url)
        state = await ShareLinkResolver().resolve(url).state
    }

    func addEpisode() {
        guard canAdd, let sharedURL else { return }
        state = .saving
        do {
            try PendingSharedEpisodeShareStore.save(.importEpisode(url: sharedURL, playlistID: selectedPlaylistID))
            state = .saved(destinationDescription)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func subscribe() {
        guard case .podcastEpisode(let podcast, _) = state, let sharedURL else { return }
        state = .saving
        do {
            try PendingSharedEpisodeShareStore.save(.subscribe(feedURL: podcast.feedURL, sharedURL: sharedURL))
            state = .saved("The podcast will open in Up Next so you can subscribe.")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func search() {
        guard let sharedURL, let query = searchQuery else { return }
        state = .saving
        do {
            try PendingSharedEpisodeShareStore.save(.search(query: query, sharedURL: sharedURL))
            state = .saved("Up Next will open Add with \(query) prefilled.")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func done() { completeOnce() }
    func cancel() { completeOnce() }

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
        guard didComplete == false else { return }
        didComplete = true
        extensionContext?.completeRequest(returningItems: nil)
    }
}

private extension ShareLinkResolution {
    var state: ShareExtensionViewModel.State {
        switch self {
        case .podcastEpisode(let podcast, let episode): return .podcastEpisode(podcast, episode)
        case .podcast(let podcast): return .podcast(podcast)
        case .standaloneMedia(let media): return .standalone(media)
        case .unresolved(let url, let query): return .unresolved(url, query)
        }
    }
}
