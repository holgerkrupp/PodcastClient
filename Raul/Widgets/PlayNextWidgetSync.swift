import Foundation
import SwiftData

#if canImport(WidgetKit)
import WidgetKit
#endif

struct PlayNextWidgetSnapshot: Codable {
    struct Item: Codable, Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let podcast: String?
        let isCurrent: Bool
    }

    let generatedAt: Date
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
    let playlists: [Item]
}

enum PlayNextWidgetSync {
    static let appGroupID = "group.de.holgerkrupp.PodcastClient"
    static let legacyFileName = "play-next-widget.json"
    static let catalogFileName = "play-next-widget-playlists.json"
    static let snapshotFilePrefix = "play-next-widget-"

    static func refresh(
        using container: ModelContainer? = nil,
        currentEpisodeURL: URL? = nil,
        playlistIDs: Set<UUID>? = nil
    ) async {
        let resolvedContainer = await MainActor.run { container ?? ModelContainerManager.shared.container }
        let modelContext = ModelContext(resolvedContainer)

        let allPlaylists = (try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? []
        let manualPlaylists = Playlist.manualVisibleSorted(allPlaylists)
        guard manualPlaylists.isEmpty == false else {
            clear()
            return
        }

        let defaultPlaylistID = manualPlaylists.first(where: { $0.title == Playlist.defaultQueueTitle })?.id
            ?? manualPlaylists.first?.id

        pruneStaleSnapshots(validPlaylistIDs: Set(manualPlaylists.map { $0.id.uuidString }))
        persistCatalog(for: manualPlaylists, defaultPlaylistID: defaultPlaylistID)

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
            let episodes = (try? await playlistActor.orderedEpisodeSummaries()) ?? []
            writeSnapshot(episodes: episodes, currentEpisodeURL: resolvedCurrentURL, playlistID: playlistID)
        }

        // Keep the legacy file in sync so existing widgets continue to work.
        if let defaultPlaylistID,
           let playlistActor = try? PlaylistModelActor(modelContainer: resolvedContainer, playlistID: defaultPlaylistID) {
            let episodes = (try? await playlistActor.orderedEpisodeSummaries()) ?? []
            writeLegacySnapshot(episodes: episodes, currentEpisodeURL: resolvedCurrentURL)
        }

        reloadWidgets()
    }

    static func clear() {
        let emptySnapshot = PlayNextWidgetSnapshot(generatedAt: .now, items: [])
        persist(emptySnapshot, fileName: legacyFileName)
        persist(PlayNextWidgetPlaylistCatalog(generatedAt: .now, playlists: []), fileName: catalogFileName)
        reloadWidgets()
    }

    private static func persistCatalog(for playlists: [Playlist], defaultPlaylistID: UUID?) {
        let items = playlists.map { playlist in
            PlayNextWidgetPlaylistCatalog.Item(
                id: playlist.id.uuidString,
                title: playlist.displayTitle,
                symbolName: playlist.displaySymbolName,
                isDefault: playlist.id == defaultPlaylistID
            )
        }
        let catalog = PlayNextWidgetPlaylistCatalog(generatedAt: .now, playlists: items)
        persist(catalog, fileName: catalogFileName)
    }

    private static func writeSnapshot(episodes: [EpisodeSummary], currentEpisodeURL: URL?, playlistID: UUID) {
        let snapshot = PlayNextWidgetSnapshot(generatedAt: .now, items: snapshotItems(from: episodes, currentEpisodeURL: currentEpisodeURL))
        persist(snapshot, fileName: snapshotFileName(for: playlistID))
    }

    private static func writeLegacySnapshot(episodes: [EpisodeSummary], currentEpisodeURL: URL?) {
        let snapshot = PlayNextWidgetSnapshot(generatedAt: .now, items: snapshotItems(from: episodes, currentEpisodeURL: currentEpisodeURL))
        persist(snapshot, fileName: legacyFileName)
    }

    private static func snapshotItems(from episodes: [EpisodeSummary], currentEpisodeURL: URL?) -> [PlayNextWidgetSnapshot.Item] {
        episodes.prefix(12).compactMap { episode in
            let title = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard title.isEmpty == false,
                  let episodeURL = episode.url else { return nil }

            return PlayNextWidgetSnapshot.Item(
                id: episodeURL.absoluteString,
                title: title,
                subtitle: episode.desc?.trimmingCharacters(in: .whitespacesAndNewlines),
                podcast: episode.podcast?.trimmingCharacters(in: .whitespacesAndNewlines),
                isCurrent: episode.url == currentEpisodeURL
            )
        }
    }

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
