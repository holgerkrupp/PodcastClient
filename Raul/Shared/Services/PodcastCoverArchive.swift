import CryptoKit
import Foundation
import SwiftUI

/// Small covers of deleted podcasts, so statistics and share pictures still show
/// them after the library row is gone. Device-local: nothing here syncs.
actor PodcastCoverArchive {
    private struct Entry: Codable {
        let feed: String
        let title: String
        let fileName: String
    }

    static let shared = PodcastCoverArchive()
    private static let maxPixelSize: CGFloat = 256

    private let directoryOverride: URL?

    init(directory: URL? = nil) {
        directoryOverride = directory
    }

    nonisolated static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PodcastCoverArchive", isDirectory: true)
    }

    /// Prefers the image already on disk, because a cancelled podcast's cover
    /// may no longer be online. Network failure just means no archived cover.
    func archive(imageURL: URL, feed: URL, title: String, profile: PodcastAccessProfile?) async {
        let image: UIImage?
        if let persisted = await ImageLoaderAndCache.loadPersistedUIImage(
            from: imageURL,
            maxPixelSize: Self.maxPixelSize
        ) {
            image = persisted
        } else {
            image = await ImageLoaderAndCache.loadUIImage(
                from: imageURL,
                maxPixelSize: Self.maxPixelSize,
                profile: profile
            )
        }
        guard let data = image?.jpegData(compressionQuality: 0.75) else { return }
        store(data, feed: feed, title: title)
    }

    func store(_ imageData: Data, feed: URL, title: String) {
        guard let directory = directoryOverride ?? Self.defaultDirectory else { return }
        let feedKey = feed.absoluteString
        let digest = SHA256.hash(data: Data(feedKey.utf8))
        let fileName = digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try imageData.write(to: directory.appendingPathComponent(fileName), options: .atomic)
            var entries = Self.loadEntries(in: directory).filter { $0.feed != feedKey }
            entries.append(Entry(feed: feedKey, title: title, fileName: fileName))
            try JSONEncoder().encode(entries).write(to: Self.indexURL(in: directory), options: .atomic)
        } catch {
            CrashBreadcrumbs.shared.record("podcast_cover_archive_write_failed")
        }
    }

    /// File URLs that can stand in for `Podcast.imageURL` wherever a library row
    /// is missing, keyed the way the statistics screens look up covers.
    nonisolated static func coverFiles(
        in directory: URL? = defaultDirectory
    ) -> (byFeed: [String: URL], byTitle: [String: URL]) {
        guard let directory else { return ([:], [:]) }
        var byFeed: [String: URL] = [:]
        var byTitle: [String: URL] = [:]
        for entry in loadEntries(in: directory) {
            let file = directory.appendingPathComponent(entry.fileName)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            byFeed[entry.feed] = file
            byTitle[entry.title] = file
        }
        return (byFeed, byTitle)
    }

    private nonisolated static func indexURL(in directory: URL) -> URL {
        directory.appendingPathComponent("index.json")
    }

    private nonisolated static func loadEntries(in directory: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: indexURL(in: directory)) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}
