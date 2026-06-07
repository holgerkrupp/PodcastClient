import Foundation
import CryptoKit
import SwiftData

#if canImport(UIKit)
import UIKit
#endif

#if canImport(WidgetKit)
import WidgetKit
#endif

struct PlayNextWidgetSnapshot: Codable {
    struct Item: Codable, Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let podcast: String?
        let coverURL: URL?
        let coverFileName: String?
        let isCurrent: Bool
    }

    let generatedAt: Date
    let totalItemCount: Int
    let currentIndex: Int?
    let items: [Item]
}

struct PlayNextWidgetPlaylistCatalog: Codable {
    struct Item: Codable, Identifiable {
        let id: String
        let title: String
        let symbolName: String
        let isDefault: Bool
    }

    let generatedAt: Date
    let selectedPlaylistID: String?
    let playlists: [Item]
}

enum PlayNextWidgetSync {
    static let appGroupID = "group.de.holgerkrupp.PodcastClient"
    static let legacyFileName = "play-next-widget.json"
    static let catalogFileName = "play-next-widget-playlists.json"
    static let snapshotFilePrefix = "play-next-widget-"
    private static let refreshCoordinator = PlayNextWidgetRefreshCoordinator()
    private static let snapshotItemLimit = 12

    static func refresh(
        using container: ModelContainer? = nil,
        currentEpisodeURL: URL? = nil,
        playlistIDs: Set<UUID>? = nil
    ) async {
        await refreshCoordinator.refresh(
            using: container,
            currentEpisodeURL: currentEpisodeURL,
            playlistIDs: playlistIDs
        )
    }

    fileprivate static func performRefresh(
        using container: ModelContainer? = nil,
        currentEpisodeURL: URL? = nil,
        playlistIDs: Set<UUID>? = nil
    ) async {
        let resolvedContainer = await MainActor.run { container ?? ModelContainerManager.shared.container }
        let modelContext = ModelContext(resolvedContainer)

        _ = Playlist.ensureDefaultQueue(in: modelContext)
        modelContext.saveIfNeeded()

        let allPlaylists = (try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? []
        let manualPlaylists = Playlist.manualVisibleSorted(allPlaylists)
        guard manualPlaylists.isEmpty == false else {
            reloadWidgets()
            return
        }

        let defaultPlaylistID = manualPlaylists.first(where: { $0.title == Playlist.defaultQueueTitle })?.id
            ?? manualPlaylists.first?.id

        pruneStaleSnapshots(validPlaylistIDs: Set(manualPlaylists.map { $0.id.uuidString }))
        let selectedPlaylistID = resolvedSelectedPlaylistID(
            from: manualPlaylists,
            defaultPlaylistID: defaultPlaylistID
        )

        persistCatalog(
            for: manualPlaylists,
            defaultPlaylistID: defaultPlaylistID,
            selectedPlaylistID: selectedPlaylistID
        )

        let resolvedCurrentURL: URL?
        if let currentEpisodeURL {
            resolvedCurrentURL = currentEpisodeURL
        } else {
            resolvedCurrentURL = await MainActor.run { Player.shared.currentEpisodeURL }
        }

        let playlistIDsToRefresh: [UUID]
        if let playlistIDs, playlistIDs.isEmpty == false {
            var targetedIDs = playlistIDs
            if let defaultPlaylistID {
                targetedIDs.insert(defaultPlaylistID)
            }
            if let selectedPlaylistID {
                targetedIDs.insert(selectedPlaylistID)
            }
            playlistIDsToRefresh = targetedIDs.filter { targetID in
                manualPlaylists.contains(where: { $0.id == targetID })
            }
        } else {
            playlistIDsToRefresh = manualPlaylists.map(\.id)
        }

        for playlistID in playlistIDsToRefresh {
            guard let playlistActor = try? PlaylistModelActor(modelContainer: resolvedContainer, playlistID: playlistID) else {
                continue
            }
            let episodes = (try? await playlistActor.orderedEpisodeSummaries(limit: snapshotItemLimit)) ?? []
            await writeSnapshot(episodes: episodes, currentEpisodeURL: resolvedCurrentURL, playlistID: playlistID)
        }

        // Keep the legacy file in sync so existing widgets continue to work.
        if let defaultPlaylistID,
           let playlistActor = try? PlaylistModelActor(modelContainer: resolvedContainer, playlistID: defaultPlaylistID) {
            let episodes = (try? await playlistActor.orderedEpisodeSummaries(limit: snapshotItemLimit)) ?? []
            await writeLegacySnapshot(episodes: episodes, currentEpisodeURL: resolvedCurrentURL)
        }

        reloadWidgets()
    }

    static func clear() {
        let emptySnapshot = PlayNextWidgetSnapshot(generatedAt: .now, totalItemCount: 0, currentIndex: nil, items: [])
        persist(emptySnapshot, fileName: legacyFileName)
        persist(PlayNextWidgetPlaylistCatalog(generatedAt: .now, selectedPlaylistID: nil, playlists: []), fileName: catalogFileName)
        reloadWidgets()
    }

    private static func persistCatalog(for playlists: [Playlist], defaultPlaylistID: UUID?, selectedPlaylistID: UUID?) {
        let items = playlists.map { playlist in
            PlayNextWidgetPlaylistCatalog.Item(
                id: playlist.id.uuidString,
                title: playlist.displayTitle,
                symbolName: playlist.displaySymbolName,
                isDefault: playlist.id == defaultPlaylistID
            )
        }
        let catalog = PlayNextWidgetPlaylistCatalog(
            generatedAt: .now,
            selectedPlaylistID: selectedPlaylistID?.uuidString,
            playlists: items
        )
        persist(catalog, fileName: catalogFileName)
    }

    private static func resolvedSelectedPlaylistID(from playlists: [Playlist], defaultPlaylistID: UUID?) -> UUID? {
        if let selectedID = Playlist.resolvePlaylistID(
            from: UserDefaults.standard.string(forKey: PlaylistPreferenceKeys.selectedPlaylistID)
        ),
           playlists.contains(where: { $0.id == selectedID }) {
            return selectedID
        }

        let fallbackID = defaultPlaylistID ?? playlists.first?.id
        if let fallbackID {
            UserDefaults.standard.set(fallbackID.uuidString, forKey: PlaylistPreferenceKeys.selectedPlaylistID)
        }
        return fallbackID
    }

    private static func writeSnapshot(episodes: [EpisodeSummary], currentEpisodeURL: URL?, playlistID: UUID) async {
        let snapshot = await makeSnapshot(from: episodes, currentEpisodeURL: currentEpisodeURL)
        persist(snapshot, fileName: snapshotFileName(for: playlistID))
    }

    private static func writeLegacySnapshot(episodes: [EpisodeSummary], currentEpisodeURL: URL?) async {
        let snapshot = await makeSnapshot(from: episodes, currentEpisodeURL: currentEpisodeURL)
        persist(snapshot, fileName: legacyFileName)
    }

    private static func makeSnapshot(from episodes: [EpisodeSummary], currentEpisodeURL: URL?) async -> PlayNextWidgetSnapshot {
        struct SnapshotSource {
            let episode: EpisodeSummary
            let title: String
            let episodeURL: URL
        }

        let sources: [SnapshotSource] = episodes.compactMap { episode in
            let title = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard title.isEmpty == false,
                  let episodeURL = episode.url else { return nil }

            return SnapshotSource(episode: episode, title: title, episodeURL: episodeURL)
        }

        var items: [PlayNextWidgetSnapshot.Item] = []
        items.reserveCapacity(min(sources.count, 12))

        for source in sources.prefix(12) {
            let coverURL = source.episode.cover ?? source.episode.podcastCover
            let coverFileName = await ensureCoverThumbnail(for: coverURL)

            items.append(PlayNextWidgetSnapshot.Item(
                id: source.episodeURL.absoluteString,
                title: source.title,
                subtitle: source.episode.desc?.trimmingCharacters(in: .whitespacesAndNewlines),
                podcast: source.episode.podcast?.trimmingCharacters(in: .whitespacesAndNewlines),
                coverURL: coverURL,
                coverFileName: coverFileName,
                isCurrent: source.episode.url == currentEpisodeURL
            ))
        }

        return PlayNextWidgetSnapshot(
            generatedAt: .now,
            totalItemCount: sources.count,
            currentIndex: sources.firstIndex { $0.episode.url == currentEpisodeURL },
            items: items
        )
    }

    private static func ensureCoverThumbnail(for coverURL: URL?) async -> String? {
        guard let coverURL,
              let directoryURL = coverThumbnailDirectoryURL()
        else { return nil }

        let fileName = "\(coverThumbnailCacheKey(for: coverURL)).jpg"
        let relativePath = "play-next-widget-covers/\(fileName)"
        let fileURL = directoryURL.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            return relativePath
        }

        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        #if canImport(UIKit)
        guard let image = await ImageLoaderAndCache.loadUIImage(from: coverURL),
              let data = await coverThumbnailData(from: image)
        else { return nil }

        do {
            try data.write(to: fileURL, options: .atomic)
            return relativePath
        } catch {
            #if DEBUG
            print("Failed to persist widget cover thumbnail: \(error)")
            #endif
            return nil
        }
        #else
        return nil
        #endif
    }

    private static func coverThumbnailDirectoryURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("play-next-widget-covers", isDirectory: true)
    }

    private static func coverThumbnailCacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    #if canImport(UIKit)
    @MainActor
    private static func coverThumbnailData(from image: UIImage) -> Data? {
        let size = CGSize(width: 96, height: 96)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let thumbnail = renderer.image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let sourceSize = image.size
            guard sourceSize.width > 0, sourceSize.height > 0 else { return }

            let scale = max(size.width / sourceSize.width, size.height / sourceSize.height)
            let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
            let drawOrigin = CGPoint(
                x: (size.width - drawSize.width) / 2,
                y: (size.height - drawSize.height) / 2
            )
            image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        }

        return thumbnail.jpegData(compressionQuality: 0.78)
    }
    #endif

    private static func snapshotFileName(for playlistID: UUID) -> String {
        "\(snapshotFilePrefix)\(playlistID.uuidString).json"
    }

    private static func pruneStaleSnapshots(validPlaylistIDs: Set<String>) {
        guard let sharedDirectoryURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return
        }

        let snapshotFiles = (try? FileManager.default.contentsOfDirectory(at: sharedDirectoryURL, includingPropertiesForKeys: nil))
            ?? []

        for fileURL in snapshotFiles {
            let fileName = fileURL.lastPathComponent
            guard fileName.hasPrefix(snapshotFilePrefix), fileName.hasSuffix(".json") else {
                continue
            }

            let playlistID = fileName
                .replacingOccurrences(of: snapshotFilePrefix, with: "")
                .replacingOccurrences(of: ".json", with: "")

            guard validPlaylistIDs.contains(playlistID) == false else { continue }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func persist<Value: Encodable>(_ value: Value, fileName: String) {
        guard let url = sharedFileURL(fileName: fileName) else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            #if DEBUG
            print("Failed to persist widget data (\(fileName)): \(error)")
            #endif
        }
    }

    private static func sharedFileURL(fileName: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(fileName)
    }

    private static func reloadWidgets() {
        #if canImport(WidgetKit)
        if #available(iOS 14.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
    }
}

private actor PlayNextWidgetRefreshCoordinator {
    private struct Request {
        var container: ModelContainer?
        var currentEpisodeURL: URL?
        var playlistIDs: Set<UUID>?

        func merged(with newer: Request) -> Request {
            let mergedPlaylistIDs: Set<UUID>?
            if playlistIDs == nil || newer.playlistIDs == nil {
                mergedPlaylistIDs = nil
            } else {
                mergedPlaylistIDs = playlistIDs!.union(newer.playlistIDs!)
            }

            return Request(
                container: newer.container ?? container,
                currentEpisodeURL: newer.currentEpisodeURL ?? currentEpisodeURL,
                playlistIDs: mergedPlaylistIDs
            )
        }
    }

    private var isRefreshing = false
    private var pendingRequest: Request?

    func refresh(
        using container: ModelContainer?,
        currentEpisodeURL: URL?,
        playlistIDs: Set<UUID>?
    ) async {
        var request = Request(
            container: container,
            currentEpisodeURL: currentEpisodeURL,
            playlistIDs: playlistIDs
        )

        if isRefreshing {
            pendingRequest = pendingRequest?.merged(with: request) ?? request
            return
        }

        isRefreshing = true

        while true {
            await PlayNextWidgetSync.performRefresh(
                using: request.container,
                currentEpisodeURL: request.currentEpisodeURL,
                playlistIDs: request.playlistIDs
            )

            guard let nextRequest = pendingRequest else {
                isRefreshing = false
                return
            }

            pendingRequest = nil
            request = nextRequest
        }
    }
}
