import Foundation

extension Notification.Name {
    static let spotlightLibraryDidChange = Notification.Name("spotlightLibraryDidChange")
}

#if canImport(CoreSpotlight) && (os(iOS) || os(macOS))
import CoreSpotlight
import CryptoKit
import SwiftData
import UniformTypeIdentifiers

private struct LocalSpotlightEntry: Sendable {
    let kind: String
    let identity: String
    let title: String
    let keywords: [String]
    let destination: URL
    let description: String
}

@ModelActor
private actor LocalSpotlightQueryActor {
    func entries() throws -> [LocalSpotlightEntry] {
        var result: [LocalSpotlightEntry] = []
        var podcasts = FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.title)])
        podcasts.fetchLimit = 500
        for podcast in try modelContext.fetch(podcasts) {
            guard let feedURL = LocalSpotlightIndexer.safePublicURL(podcast.feed),
                  podcast.metaData?.accessProfileID == nil,
                  let destination = LocalSpotlightIndexer.appURL(host: "podcast", name: "feed", value: feedURL.absoluteString) else { continue }
            result.append(LocalSpotlightEntry(
                kind: "podcast",
                identity: feedURL.absoluteString,
                title: podcast.title,
                keywords: ["podcast", "subscription"],
                destination: destination,
                description: "Podcast in your library"
            ))
        }

        var episodes = FetchDescriptor<Episode>(sortBy: [SortDescriptor(\.publishDate, order: .reverse)])
        episodes.fetchLimit = 1_000
        for episode in try modelContext.fetch(episodes) {
            guard let file = episode.localFile, FileManager.default.fileExists(atPath: file.path),
                  let episodeURL = LocalSpotlightIndexer.safePublicURL(episode.url),
                  let podcast = episode.podcast, podcast.metaData?.accessProfileID == nil,
                  LocalSpotlightIndexer.safePublicURL(podcast.feed) != nil,
                  let destination = LocalSpotlightIndexer.appURL(host: "episode", name: "url", value: episodeURL.absoluteString) else { continue }
            result.append(LocalSpotlightEntry(
                kind: "episode",
                identity: episodeURL.absoluteString,
                title: episode.title,
                keywords: ["podcast", "episode", podcast.title],
                destination: destination,
                description: "Downloaded episode from \(podcast.title)"
            ))
        }
        return result
    }
}

enum LocalSpotlightIndexer {
    static let settingKey = "localSpotlightIndexingEnabled"
    private static let domain = "com.holgerkrupp.upnext.library"
    private static let batchSize = 100
    private static let indexedIDsKey = "localSpotlightIndexedIDs"
    private static let signatureKey = "localSpotlightIndexSignature"

    @MainActor
    static func refresh(container: ModelContainer, force: Bool = false) async {
        guard UserDefaults.standard.bool(forKey: settingKey) else {
            try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
            UserDefaults.standard.removeObject(forKey: indexedIDsKey)
            UserDefaults.standard.removeObject(forKey: signatureKey)
            return
        }

        let entries = (try? await LocalSpotlightQueryActor(modelContainer: container).entries()) ?? []
        var items: [CSSearchableItem] = []

        for entry in entries {
            let item = searchableItem(kind: entry.kind, identity: entry.identity, title: entry.title, keywords: entry.keywords)
            item.attributeSet.contentDescription = entry.description
            item.attributeSet.relatedUniqueIdentifier = domain
            item.attributeSet.url = entry.destination
            items.append(item)
        }

        let signature = items.map { "\($0.uniqueIdentifier)|\($0.attributeSet.title ?? "")" }.sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        guard force || UserDefaults.standard.string(forKey: signatureKey) != digest else { return }

        let index = CSSearchableIndex.default()
        do {
            for start in stride(from: 0, to: items.count, by: batchSize) {
                try Task.checkCancellation()
                try await index.indexSearchableItems(Array(items[start..<min(start + batchSize, items.count)]))
            }
            let currentIDs = items.compactMap(\.uniqueIdentifier)
            let previousIDs = UserDefaults.standard.stringArray(forKey: indexedIDsKey) ?? []
            let removedIDs = Set(previousIDs).subtracting(currentIDs)
            if removedIDs.isEmpty == false {
                try await index.deleteSearchableItems(withIdentifiers: Array(removedIDs))
            }
            UserDefaults.standard.set(currentIDs, forKey: indexedIDsKey)
            UserDefaults.standard.set(digest, forKey: signatureKey)
        } catch {
            // Spotlight is an optional local search surface; the library remains usable.
        }
    }

    private static func searchableItem(kind: String, identity: String, title: String, keywords: [String]) -> CSSearchableItem {
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = title
        attributes.keywords = keywords
        return CSSearchableItem(uniqueIdentifier: "\(kind).\(digest)", domainIdentifier: domain, attributeSet: attributes)
    }

    fileprivate static func appURL(host: String, name: String, value: String) -> URL? {
        var components = URLComponents()
        components.scheme = "upnext"
        components.host = host
        components.queryItems = [URLQueryItem(name: name, value: value)]
        return components.url
    }

    fileprivate static func safePublicURL(_ url: URL?) -> URL? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.queryItems?.isEmpty != false,
              components.scheme == "https" || components.scheme == "http" else { return nil }
        return url
    }
}
#endif
