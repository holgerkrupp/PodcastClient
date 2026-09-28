import Combine
import Foundation

@MainActor
final class ShareExtensionViewModel: ObservableObject {
    enum State: Equatable {
        case loading
        case ready
        case saving
        case saved
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var playlists: [SharedEpisodePlaylistSnapshot] = []
    @Published var selectedPlaylistID: UUID?

    private var extensionContext: NSExtensionContext?
    private var sharedURL: URL?
    private var completionTask: Task<Void, Never>?
    private var didComplete = false

    var canAdd: Bool {
        state == .ready && sharedURL != nil
    }

    var sharedHost: String? {
        sharedURL?.host()
    }

    func prepare(extensionContext: NSExtensionContext?) async {
        guard state == .loading else { return }

        do {
            guard let extensionContext else {
                throw ShareExtensionError.missingExtensionContext
            }
            guard let url = await SharedURLExtractor.firstURL(
                in: extensionContext.inputItems
            ) else {
                throw ShareExtensionError.noURL
            }

            self.extensionContext = extensionContext
            sharedURL = url
            playlists = PendingSharedEpisodeShareStore.playlists()
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func add() {
        guard canAdd, let sharedURL else { return }
        state = .saving

        do {
            try PendingSharedEpisodeShareStore.save(
                sharedURL,
                playlistID: selectedPlaylistID
            )
            state = .saved
            completionTask?.cancel()
            completionTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard Task.isCancelled == false else { return }
                self?.completeOnce()
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        completionTask?.cancel()
        completeOnce()
    }

    private func completeOnce() {
        guard didComplete == false else { return }
        didComplete = true
        extensionContext?.completeRequest(returningItems: nil)
    }
}
