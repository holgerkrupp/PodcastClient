import SwiftUI
import OSLog

#if canImport(UIKit)
import UIKit

@MainActor
final class ShareViewController: UIViewController {
    private var viewModel: ShareExtensionViewModel?
    private var handlingTask: Task<Void, Never>?

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        ShareExtensionDiagnostics.log("controller.init.nibName")
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required dynamic init?(coder aDecoder: NSCoder) {
        ShareExtensionDiagnostics.log("controller.init")
        super.init(coder: aDecoder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        ShareExtensionDiagnostics.log("controller.viewDidLoad")
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
        ShareExtensionDiagnostics.log("controller.viewDidAppear")
        startHandlingIfNeeded()
    }

    private func startHandlingIfNeeded() {
        guard handlingTask == nil, let viewModel else { return }

        ShareExtensionDiagnostics.log("handling.start")
        let context = extensionContext
        handlingTask = Task {
            await viewModel.prepare(extensionContext: context)
            ShareExtensionDiagnostics.log(Task.isCancelled ? "handling.cancelled" : "handling.finished")
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        ShareExtensionDiagnostics.log("controller.viewDidDisappear")
        stopHandling(reason: "controller.disappeared")
    }

    private func stopHandling(reason: String) {
        ShareExtensionDiagnostics.log(reason)
        handlingTask?.cancel()
        handlingTask = nil
        viewModel?.stopHandling()
    }
}
#elseif canImport(AppKit)
import AppKit
import OSLog

final class ShareViewController: NSHostingController<ShareExtensionView> {
    private let viewModel: ShareExtensionViewModel
    private var handlingTask: Task<Void, Never>?

    @MainActor
    required dynamic init?(coder: NSCoder) {
        ShareExtensionDiagnostics.log("controller.init")
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
        ShareExtensionDiagnostics.log("controller.viewDidAppear")
        startHandlingIfNeeded()
    }

    @MainActor
    private func startHandlingIfNeeded() {
        guard handlingTask == nil else { return }

        ShareExtensionDiagnostics.log("handling.start")
        let context = extensionContext
        handlingTask = Task {
            await viewModel.prepare(extensionContext: context)
            ShareExtensionDiagnostics.log(Task.isCancelled ? "handling.cancelled" : "handling.finished")
        }
    }

    @MainActor
    override func viewDidDisappear() {
        super.viewDidDisappear()
        ShareExtensionDiagnostics.log("controller.viewDidDisappear")
        handlingTask?.cancel()
        handlingTask = nil
        viewModel.stopHandling()
    }
}
#endif

enum ShareExtensionDiagnostics {
    private static let logger = Logger(subsystem: "de.holgerkrupp.PodcastClient", category: "ShareExtension")

    static func log(_ event: String) {
        logger.info("\(event, privacy: .public)")
    }
}
