import SwiftUI

#if canImport(UIKit)
import UIKit

@MainActor
final class ShareViewController: UIViewController {
    private var viewModel: ShareExtensionViewModel?
    private var handlingTask: Task<Void, Never>?

    required dynamic init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let viewModel = ShareExtensionViewModel()
        self.viewModel = viewModel

        let hostingController = UIHostingController(
            rootView: ShareExtensionView(viewModel: viewModel)
        )
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startHandlingIfNeeded()
    }

    private func startHandlingIfNeeded() {
        guard handlingTask == nil, let viewModel else { return }

        handlingTask = Task {
            await viewModel.prepare(extensionContext: extensionContext)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
        handlingTask?.cancel()
        handlingTask = nil
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
            await viewModel.prepare(extensionContext: extensionContext)
        }
    }
}
#endif
