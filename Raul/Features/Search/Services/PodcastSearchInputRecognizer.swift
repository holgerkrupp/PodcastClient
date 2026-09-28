import Foundation

/// Separates direct podcast URLs from text intended for the podcast catalogue.
/// SwiftUI's searchable field remains responsible for paste and all other text
/// editing, so this type never reads the system pasteboard.
struct PodcastSearchInputRecognizer {
    /// Uses a trimmed copy for interpretation without rewriting the search text.
    static func url(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let components = URLComponents(string: trimmed)
        else {
            return nil
        }

        if let scheme = components.scheme?.lowercased() {
            guard supportedSchemes.contains(scheme),
                  let url = URL(string: trimmed),
                  hasUsableHost(for: components)
            else {
                return nil
            }
            return url
        }

        // Preserve the existing convenience of accepting a bare host/path,
        // while requiring a dotted host so punctuation in ordinary search
        // terms does not divert them from catalogue search.
        guard trimmed.contains(".") else { return nil }
        let candidate = "https://\(trimmed)"
        guard let candidateComponents = URLComponents(string: candidate),
              let url = URL(string: candidate),
              hasUsableHost(for: candidateComponents)
        else {
            return nil
        }
        return url
    }

    private static let supportedSchemes: Set<String> = [
        "http", "https", "feed", "rss", "pcast", "upnext"
    ]

    private static func hasUsableHost(for components: URLComponents) -> Bool {
        guard let host = components.host, host.isEmpty == false else { return false }
        return host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }
}
