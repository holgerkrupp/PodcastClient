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
        let progress: Double?
    }

    let generatedAt: Date
    let totalItemCount: Int
    let currentIndex: Int?
    let items: [Item]
}

/// Playback-only state for the Now Playing widget. This intentionally stays
/// separate from playlist snapshots so transport changes never fetch SwiftData
/// or rebuild queue artwork.
struct WidgetPlaybackSnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    let updatedAt: Date
    let episodeID: String?
    let isPlaying: Bool
    let positionSeconds: Double?
    let durationSeconds: Double?
    let playbackRate: Double?
    let title: String?
    let podcastTitle: String?
    let coverFileName: String?
    let backgroundFileName: String?
    let skipBackSymbol: String?
    let skipForwardSymbol: String?
    let skipBackSeconds: Int?
    let skipForwardSeconds: Int?

    func hasSamePlaybackContent(as other: WidgetPlaybackSnapshot) -> Bool {
        episodeID == other.episodeID &&
        isPlaying == other.isPlaying &&
        positionSeconds == other.positionSeconds &&
        durationSeconds == other.durationSeconds &&
        playbackRate == other.playbackRate &&
        title == other.title &&
        podcastTitle == other.podcastTitle &&
        coverFileName == other.coverFileName &&
        backgroundFileName == other.backgroundFileName &&
        skipBackSymbol == other.skipBackSymbol &&
        skipForwardSymbol == other.skipForwardSymbol &&
        skipBackSeconds == other.skipBackSeconds &&
        skipForwardSeconds == other.skipForwardSeconds
    }

    var playbackProgress: Double? {
        guard let positionSeconds, let durationSeconds,
              positionSeconds.isFinite, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        return min(max(positionSeconds / durationSeconds, 0), 1)
    }
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
    static let playbackFileName = "play-next-widget-playback-v1.json"
    private static let refreshCoordinator = PlayNextWidgetRefreshCoordinator()
    private static let snapshotItemLimit = 12
    @MainActor private static var lastPositionOnlyPublicationAt = Date.distantPast
    private static let playbackSnapshotWriter = WidgetPlaybackSnapshotWriter()

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
        let resolvedContainer: ModelContainer?
        if let container {
            resolvedContainer = container
        } else {
            // Widget refreshes can be requested from a cold notification or
            // background launch. Do not force the manager's precondition-only
            // accessor before the runtime graph is ready.
            resolvedContainer = await ModelContainerManager.shared
                .prepareContainerForExternalEntryPoint()
        }
        guard let resolvedContainer else {
            reloadWidgets()
            return
        }
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
            if #available(iOS 27.0, macOS 27.0, *) {
                await UpNextRelevantEntitiesPublisher.shared.publish(episodes)
            }
        }

        reloadWidgets()
    }

    static func clear() {
        let emptySnapshot = PlayNextWidgetSnapshot(generatedAt: .now, totalItemCount: 0, currentIndex: nil, items: [])
        persist(emptySnapshot, fileName: legacyFileName)
        persist(PlayNextWidgetPlaylistCatalog(generatedAt: .now, selectedPlaylistID: nil, playlists: []), fileName: catalogFileName)
        reloadWidgets()
    }

    /// Publishes only values already held by Player. Resolved player artwork
    /// may be chapter-specific, so persist it into the app-group thumbnail cache
    /// before falling back to a previously cached episode cover.
    @MainActor
    static func publishPlaybackState() async {
        lastPositionOnlyPublicationAt = .now
        let player = Player.shared
        let episode = player.currentEpisode
        let podcastArtworkURL = episode?.imageURL ?? episode?.podcast?.imageURL
        let artworkURL = podcastArtworkURL ?? episode?.url
        let backgroundFileName = podcastArtworkURL.flatMap { cachedCoverThumbnailName(for: $0) }
        let coverFileName: String?
        if let artwork = player.currentArtworkImage, let artworkURL {
            coverFileName = persistCurrentArtworkThumbnail(artwork, for: artworkURL)
                ?? cachedCoverThumbnailName(for: artworkURL)
        } else {
            coverFileName = artworkURL.flatMap { cachedCoverThumbnailName(for: $0) }
        }
        let snapshot = WidgetPlaybackSnapshot(
            updatedAt: .now,
            episodeID: player.currentEpisodeURL.flatMap(publicWidgetEpisodeID),
            isPlaying: player.isPlaying,
            positionSeconds: finiteNonnegative(player.playPosition),
            durationSeconds: episode?.duration.flatMap(finitePositive),
            playbackRate: finitePositive(Double(player.playbackRate)),
            title: episode?.title,
            podcastTitle: episode?.podcast?.title,
            coverFileName: coverFileName,
            backgroundFileName: backgroundFileName,
            skipBackSymbol: player.skipBackStep.triangleBackString,
            skipForwardSymbol: player.skipForwardStep.triangleForwardString,
            skipBackSeconds: player.skipBackStep.rawValue,
            skipForwardSeconds: player.skipForwardStep.rawValue
        )
        await playbackSnapshotWriter.write(
            snapshot,
            appGroupID: appGroupID,
            fileName: playbackFileName
        )
    }

    /// Position snapshots are deliberately coarse. The player can emit more
    /// frequent progress events, but widgets only need a minute-level estimate.
    @MainActor
    static func publishPlaybackPositionIfDue() async {
        guard Player.shared.isPlaying,
              Date.now.timeIntervalSince(lastPositionOnlyPublicationAt) >= 60 else { return }
        await publishPlaybackState()
    }

    private static func cachedCoverThumbnailName(for coverURL: URL) -> String? {
        let name = "\(coverThumbnailCacheKey(for: coverURL)).jpg"
        let relativePath = "play-next-widget-covers/\(name)"
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(relativePath).path) else {
            return nil
        }
        return relativePath
    }

    #if canImport(UIKit)
    @MainActor
    private static func persistCurrentArtworkThumbnail(_ image: UIImage, for artworkURL: URL) -> String? {
        guard let directoryURL = coverThumbnailDirectoryURL(),
              let data = coverThumbnailData(from: image) else { return nil }

        // Include the image contents so a chapter-art change gets a new path.
        // The snapshot writer can then detect the change and reload the widget
        // even when the episode URL stays the same.
        let imageDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let fileName = "\(coverThumbnailCacheKey(for: artworkURL))-\(imageDigest).jpg"
        let fileURL = directoryURL.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            return "play-next-widget-covers/\(fileName)"
        } catch {
            #if DEBUG
            print("Failed to persist resolved widget artwork: \(error)")
            #endif
            return nil
        }
    }
    #endif

    private static func finiteNonnegative(_ value: Double) -> Double? {
        value.isFinite ? max(value, 0) : nil
    }

    private static func finitePositive(_ value: Double) -> Double? {
        value.isFinite && value > 0 ? value : nil
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
                id: widgetEpisodeID(for: source.episodeURL),
                title: source.title,
                subtitle: source.episode.desc?.trimmingCharacters(in: .whitespacesAndNewlines),
                podcast: source.episode.podcast?.trimmingCharacters(in: .whitespacesAndNewlines),
                coverURL: nil,
                coverFileName: coverFileName,
                isCurrent: source.episode.url == currentEpisodeURL,
                progress: source.episode.playProgress
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

    private static func publicWidgetEpisodeID(_ url: URL) -> String? {
        guard url.isLikelyPrivatePodcastURL == false else { return nil }
        return url.absoluteString
    }

    private static func widgetEpisodeID(for url: URL) -> String {
        guard url.isLikelyPrivatePodcastURL else { return url.absoluteString }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return "private-" + digest.map { String(format: "%02x", $0) }.joined()
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

private actor WidgetPlaybackSnapshotWriter {
    func write(_ snapshot: WidgetPlaybackSnapshot, appGroupID: String, fileName: String) {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(fileName) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let previousSnapshot = (try? Data(contentsOf: url))
            .flatMap { try? decoder.decode(WidgetPlaybackSnapshot.self, from: $0) }
        if let previousSnapshot,
           previousSnapshot.updatedAt > snapshot.updatedAt {
            return
        }
        if let previousSnapshot,
           previousSnapshot.hasSamePlaybackContent(as: snapshot) {
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        let shouldReloadQueue = previousSnapshot == nil ||
            previousSnapshot?.episodeID != snapshot.episodeID ||
            previousSnapshot?.isPlaying != snapshot.isPlaying ||
            previousSnapshot?.playbackProgress != snapshot.playbackProgress
        do {
            try data.write(to: url, options: .atomic)
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: "UpNextNowPlayingWidget")
            if shouldReloadQueue {
                WidgetCenter.shared.reloadTimelines(ofKind: "PlayNextQueueWidget")
            }
            #endif
        } catch {
            #if DEBUG
            print("Failed to persist widget playback state: \(error)")
            #endif
        }
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
