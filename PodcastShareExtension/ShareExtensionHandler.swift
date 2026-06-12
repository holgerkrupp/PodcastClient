import Foundation

@MainActor
struct ShareExtensionHandler {
    private let extensionContext: NSExtensionContext?
    private let viewModel: ShareExtensionViewModel

    init(
        extensionContext: NSExtensionContext?,
        viewModel: ShareExtensionViewModel
    ) {
        self.extensionContext = extensionContext
        self.viewModel = viewModel
    }

    func run() async {
        do {
            guard let extensionContext else {
                throw ShareExtensionError.missingExtensionContext
            }

            guard let url = await SharedURLExtractor.firstURL(
                in: extensionContext.inputItems
            ) else {
                throw ShareExtensionError.noURL
            }

            try PendingSharedEpisodeShareStore.save(url)
            viewModel.status = "Added to Up Next"
            try await Task.sleep(for: .milliseconds(500))
            extensionContext.completeRequest(returningItems: nil)
        } catch is CancellationError {
            extensionContext?.cancelRequest(withError: CancellationError())
        } catch {
            let failure = error
            viewModel.status = failure.localizedDescription

            do {
                try await Task.sleep(for: .seconds(1))
            } catch is CancellationError {
                extensionContext?.cancelRequest(withError: CancellationError())
                return
            } catch {
                extensionContext?.cancelRequest(withError: failure)
                return
            }

            extensionContext?.cancelRequest(withError: failure)
        }
    }
}
