import Foundation
import UniformTypeIdentifiers

enum SharedURLExtractor {
    private static let preferredTypeIdentifiers = [
        UTType.url.identifier,
        UTType.plainText.identifier,
        UTType.html.identifier
    ]

    @MainActor
    static func firstURL(in inputItems: [Any]) async -> URL? {
        for case let item as NSExtensionItem in inputItems {
            if let url = url(in: item.attributedTitle?.string)
                ?? url(in: item.attributedContentText?.string) {
                return url
            }

            for provider in item.attachments ?? [] {
                if let url = await firstURL(from: provider) {
                    return url
                }
            }
        }

        return nil
    }

    static func url(in string: String?) -> URL? {
        guard let string else { return nil }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let directURL = URL(string: trimmed), isSupported(directURL) {
            return directURL
        }

        let pattern = #"(?:https?|feed|rss)://[^\s<>"']+"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              let matchRange = Range(match.range, in: trimmed) else {
            return nil
        }

        let trailingPunctuation = CharacterSet(charactersIn: ".,);]}")
        let rawURL = String(trimmed[matchRange])
            .trimmingCharacters(in: trailingPunctuation)

        guard let url = URL(string: rawURL), isSupported(url) else {
            return nil
        }

        return url
    }

    static func url(in value: Any) -> URL? {
        if let url = value as? URL {
            return isSupported(url) ? url : nil
        }

        if let url = value as? NSURL {
            let bridgedURL = url as URL
            return isSupported(bridgedURL) ? bridgedURL : nil
        }

        if let string = value as? String {
            return url(in: string)
        }

        if let attributedString = value as? NSAttributedString {
            return url(in: attributedString.string)
        }

        if let data = value as? Data {
            return url(in: String(data: data, encoding: .utf8))
        }

        if let values = value as? [AnyHashable: Any] {
            for nestedValue in values.values {
                if let url = url(in: nestedValue) {
                    return url
                }
            }
        }

        if let values = value as? [Any] {
            for nestedValue in values {
                if let url = url(in: nestedValue) {
                    return url
                }
            }
        }

        return nil
    }

    @MainActor
    private static func firstURL(from provider: NSItemProvider) async -> URL? {
        let preferredIdentifiers = preferredTypeIdentifiers.filter {
            provider.hasItemConformingToTypeIdentifier($0)
        }
        let remainingIdentifiers = provider.registeredTypeIdentifiers.filter {
            preferredIdentifiers.contains($0) == false
        }

        for typeIdentifier in preferredIdentifiers + remainingIdentifiers {
            guard let item = try? await provider.loadItem(
                forTypeIdentifier: typeIdentifier
            ) else {
                continue
            }

            if let url = url(in: item) {
                return url
            }
        }

        return nil
    }

    private static func isSupported(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        return ["http", "https", "feed", "rss"].contains(scheme)
    }
}
