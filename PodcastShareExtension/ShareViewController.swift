import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        statusLabel.text = "Adding Episode..."
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        Task {
            await handleSharedItem()
        }
    }

    @MainActor
    private func handleSharedItem() async {
        do {
            guard let url = try await firstSharedURL() else {
                throw ShareExtensionError.noURL
            }

            PendingSharedEpisodeShareStore.save(url)
            statusLabel.text = "Added to Up Next"
            try await Task.sleep(nanoseconds: 800_000_000)
            try await openHostApp(for: url)
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            statusLabel.text = error.localizedDescription
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.extensionContext?.cancelRequest(withError: error)
            }
        }
    }

    private func firstSharedURL() async throws -> URL? {
        guard let inputItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            return nil
        }

        for item in inputItems {
            if let url = SharedURLExtractor.url(in: item.attributedTitle?.string) ?? SharedURLExtractor.url(in: item.attributedContentText?.string) {
                return url
            }

            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try await loadURL(from: provider, typeIdentifier: UTType.url.identifier) {
                    return url
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let string = try await loadString(from: provider, typeIdentifier: UTType.plainText.identifier),
                   let url = SharedURLExtractor.url(in: string) {
                    return url
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.html.identifier),
                   let string = try await loadString(from: provider, typeIdentifier: UTType.html.identifier),
                   let url = SharedURLExtractor.url(in: string) {
                    return url
                }

                for typeIdentifier in provider.registeredTypeIdentifiers {
                    if let url = try await loadURL(from: provider, typeIdentifier: typeIdentifier) {
                        return url
                    }
                }
            }
        }

        return nil
    }

    private func loadURL(from provider: NSItemProvider, typeIdentifier: String) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let url = item as? NSURL {
                    continuation.resume(returning: url as URL)
                } else if let string = item as? String {
                    continuation.resume(returning: SharedURLExtractor.url(in: string))
                } else if let attributedString = item as? NSAttributedString {
                    continuation.resume(returning: SharedURLExtractor.url(in: attributedString.string))
                } else if let data = item as? Data {
                    let string = String(data: data, encoding: .utf8)
                    continuation.resume(returning: SharedURLExtractor.url(in: string))
                } else if let data = item as? NSData {
                    let string = String(data: data as Data, encoding: .utf8)
                    continuation.resume(returning: SharedURLExtractor.url(in: string))
                } else if let values = item as? [AnyHashable: Any] {
                    continuation.resume(returning: SharedURLExtractor.url(in: values))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadString(from provider: NSItemProvider, typeIdentifier: String) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let string = item as? String {
                    continuation.resume(returning: string)
                } else if let attributedString = item as? NSAttributedString {
                    continuation.resume(returning: attributedString.string)
                } else if let data = item as? Data {
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                } else if let data = item as? NSData {
                    continuation.resume(returning: String(data: data as Data, encoding: .utf8))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

}

private enum PendingSharedEpisodeShareStore {
    private static let appGroupID = "group.de.holgerkrupp.PodcastClient"
    private static let pendingURLKey = "PendingSharedEpisodeURL"

    static func save(_ url: URL) {
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(url.absoluteString, forKey: pendingURLKey)
        defaults?.synchronize()
    }
}

private enum SharedURLExtractor {
    static func url(in string: String?) -> URL? {
        guard let string else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let directURL = URL(string: trimmed), isSupportedSharedURL(directURL) {
            return directURL
        }

        let pattern = #"https?://[^\s<>"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              let matchRange = Range(match.range, in: trimmed) else {
            return nil
        }

        let rawURL = String(trimmed[matchRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,);]"))
        guard let url = URL(string: rawURL), isSupportedSharedURL(url) else {
            return nil
        }
        return url
    }

    static func url(in values: [AnyHashable: Any]) -> URL? {
        for value in values.values {
            if let url = value as? URL {
                return url
            }

            if let url = value as? NSURL {
                return url as URL
            }

            if let string = value as? String, let url = url(in: string) {
                return url
            }

            if let attributedString = value as? NSAttributedString, let url = url(in: attributedString.string) {
                return url
            }

            if let nestedValues = value as? [AnyHashable: Any], let url = url(in: nestedValues) {
                return url
            }

            if let array = value as? [Any] {
                for element in array {
                    if let string = element as? String, let url = url(in: string) {
                        return url
                    }
                    if let nestedValues = element as? [AnyHashable: Any], let url = url(in: nestedValues) {
                        return url
                    }
                }
            }
        }

        return nil
    }

    private static func isSupportedSharedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        return scheme == "http"
            || scheme == "https"
            || scheme == "feed"
            || scheme == "rss"
    }
}

private extension ShareViewController {
    @MainActor
    func openHostApp(for sharedURL: URL) async throws {
        guard var components = URLComponents(string: "upnext://shareEpisode") else {
            throw ShareExtensionError.invalidCallbackURL
        }

        components.queryItems = [
            URLQueryItem(name: "url", value: sharedURL.absoluteString)
        ]

        guard let callbackURL = components.url else {
            throw ShareExtensionError.invalidCallbackURL
        }

        if let extensionContext,
           await open(callbackURL, with: extensionContext) {
            return
        }

        if openWithResponderChain(callbackURL) {
            return
        }

        throw ShareExtensionError.openFailed
    }

    func open(_ url: URL, with extensionContext: NSExtensionContext) async -> Bool {
        await withCheckedContinuation { continuation in
            extensionContext.open(url) { success in
                continuation.resume(returning: success)
            }
        }
    }

    func openWithResponderChain(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self

        while let currentResponder = responder {
            if currentResponder.responds(to: selector) {
                currentResponder.perform(selector, with: url)
                return true
            }

            responder = currentResponder.next
        }

        return false
    }
}

private enum ShareExtensionError: LocalizedError {
    case noURL
    case invalidCallbackURL
    case openFailed

    var errorDescription: String? {
        switch self {
        case .noURL:
            return "No URL was shared."
        case .invalidCallbackURL:
            return "The callback URL could not be created."
        case .openFailed:
            return "The app could not be opened."
        }
    }
}
