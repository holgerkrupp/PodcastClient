import Foundation
import SwiftData

#if canImport(WidgetKit)
import WidgetKit
#endif

struct PlayNextWidgetSnapshot: Codable {
    struct Item: Codable, Identifiable {
        let id: UUID
        let title: String
        let subtitle: String?
        let podcast: String?
        let isCurrent: Bool
    }

    let generatedAt: Date
    let items: [Item]
}

enum PlayNextWidgetSync {
    static let appGroupID = "group.de.holgerkrupp.PodcastClient"
    static let fileName = "play-next-widget.json"

    static func refresh(
        using container: ModelContainer? = nil,
        currentEpisodeID: UUID? = nil
    ) async {
        let resolvedContainer = await MainActor.run { container ?? ModelContainerManager.shared.container }
        guard let playlistActor = try? PlaylistModelActor(modelContainer: resolvedContainer) else { return }
        let episodes = (try? await playlistActor.orderedEpisodeSummaries()) ?? []
        let resolvedCurrentID: UUID?
        if let currentEpisodeID {
            resolvedCurrentID = currentEpisodeID
        } else {
            resolvedCurrentID = await MainActor.run { Player.shared.currentEpisodeID }
        }
        writeSnapshot(episodes: episodes, currentEpisodeID: resolvedCurrentID)
    }

    static func clear() {
        let snapshot = PlayNextWidgetSnapshot(generatedAt: .now, items: [])
        persist(snapshot)
    }

    private static func writeSnapshot(episodes: [EpisodeSummary], currentEpisodeID: UUID?) {
        let items: [PlayNextWidgetSnapshot.Item] = episodes.prefix(12).compactMap { episode in
            let title = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard title.isEmpty == false else { return nil }

            return PlayNextWidgetSnapshot.Item(
                id: episode.id,
                title: title,
                subtitle: episode.desc?.trimmingCharacters(in: .whitespacesAndNewlines),
                podcast: episode.podcast?.trimmingCharacters(in: .whitespacesAndNewlines),
                isCurrent: episode.id == currentEpisodeID
            )
        }

        persist(PlayNextWidgetSnapshot(generatedAt: .now, items: items))
    }

    private static func persist(_ snapshot: PlayNextWidgetSnapshot) {
        guard let url = sharedFileURL() else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
            reloadWidgets()
        } catch {
            #if DEBUG
            print("Failed to persist widget snapshot: \(error)")
            #endif
        }
    }

    private static func sharedFileURL() -> URL? {
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
