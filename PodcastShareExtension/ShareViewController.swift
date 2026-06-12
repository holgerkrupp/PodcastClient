import SwiftUI

#if canImport(UIKit)
import UIKit

final class ShareViewController: UIHostingController<ShareExtensionView> {
    private let viewModel: ShareExtensionViewModel
    private var handlingTask: Task<Void, Never>?

    @MainActor
    required dynamic init?(coder aDecoder: NSCoder) {
        let viewModel = ShareExtensionViewModel()
        self.viewModel = viewModel
        super.init(
            coder: aDecoder,
            rootView: ShareExtensionView(viewModel: viewModel)
        )
    }

    @MainActor
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startHandlingIfNeeded()
    }

    @MainActor
    private func startHandlingIfNeeded() {
        guard handlingTask == nil else { return }

        handlingTask = Task {
            await ShareExtensionHandler(
                extensionContext: extensionContext,
                viewModel: viewModel
            ).run()
        }
    }
}
#elseif canImport(AppKit)
import AppKit

final class ShareViewController: NSHostingController<ShareExtensionView> {
    private let viewModel: ShareExtensionViewModel
    private var handlingTask: Task<Void, Never>?

    @MainActor
    required dynamic init?(coder: NSCoder) {
        let viewModel = ShareExtensionViewModel()
        self.viewModel = viewModel
        super.init(
            coder: coder,
            rootView: ShareExtensionView(viewModel: viewModel)
        )
    }

    @MainActor
    override func viewDidAppear() {
        super.viewDidAppear()
        startHandlingIfNeeded()
    }

    @MainActor
    private func startHandlingIfNeeded() {
        guard handlingTask == nil else { return }

        handlingTask = Task {
            await ShareExtensionHandler(
                extensionContext: extensionContext,
                viewModel: viewModel
            ).run()
        }
    }
}
#endif
