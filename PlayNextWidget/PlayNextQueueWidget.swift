import AppIntents
import SwiftUI
import WidgetKit

#if canImport(UIKit)
import UIKit
#endif

private extension Color {
    static let upNextAccent = Color("AccentColor")
}

struct QueueSnapshot: Codable {
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
    let totalItemCount: Int?
    let currentIndex: Int?
    let items: [Item]
}

struct QueuePlaylistCatalog: Codable {
    struct Item: Codable, Identifiable, Hashable {
        let id: String
        let title: String
        let symbolName: String
        let isDefault: Bool
    }

    let generatedAt: Date
    let selectedPlaylistID: String?
    let playlists: [Item]
}

struct QueueTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: QueueSnapshot
    let playlistID: String
    let playlistTitle: String
    let statusMessage: String?
}

struct QueuePlaylistEntity: AppEntity, Identifiable, Hashable {
    typealias ID = String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playlist")
    static let defaultQuery = QueuePlaylistQuery()

    let id: String
    let title: String
    let symbolName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            image: .init(systemName: symbolName)
        )
    }
}

struct QueuePlaylistQuery: EntityQuery {
    func entities(for identifiers: [QueuePlaylistEntity.ID]) async throws -> [QueuePlaylistEntity] {
        let optionsByID = Dictionary(uniqueKeysWithValues: QueueProvider.loadPlaylistOptions().map { ($0.id, $0) })
        return identifiers.compactMap { identifier in
            if identifier == QueueProvider.currentPlaylistOption.id {
                return QueuePlaylistEntity(
                    id: QueueProvider.currentPlaylistOption.id,
                    title: QueueProvider.currentPlaylistOption.title,
                    symbolName: QueueProvider.currentPlaylistOption.symbolName
                )
            }

            guard let option = optionsByID[identifier] else { return nil }
            return QueuePlaylistEntity(
                id: option.id,
                title: option.title,
                symbolName: option.symbolName
            )
        }
    }

    func suggestedEntities() async throws -> [QueuePlaylistEntity] {
        ([QueueProvider.currentPlaylistOption] + QueueProvider.loadPlaylistOptions()).map { option in
            QueuePlaylistEntity(
                id: option.id,
                title: option.title,
                symbolName: option.symbolName
            )
        }
    }

    func defaultResult() async -> QueuePlaylistEntity? {
        QueuePlaylistEntity(
            id: QueueProvider.currentPlaylistOption.id,
            title: QueueProvider.currentPlaylistOption.title,
            symbolName: QueueProvider.currentPlaylistOption.symbolName
        )
    }
}

struct QueueConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Playlist"
    static let description = IntentDescription("Choose which playlist this widget should show.")
    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$playlist)")
    }

    @Parameter(title: "Playlist")
    var playlist: QueuePlaylistEntity?
}

struct QueueProvider: AppIntentTimelineProvider {
    static let appGroupID = "group.de.holgerkrupp.PodcastClient"
    static let legacyFileName = "play-next-widget.json"
    static let catalogFileName = "play-next-widget-playlists.json"
    static let snapshotFilePrefix = "play-next-widget-"
    static let currentPlaylistOptionID = "__current_playlist__"

    static let currentPlaylistOption = QueuePlaylistCatalog.Item(
        id: currentPlaylistOptionID,
        title: "Current Playlist",
        symbolName: "rectangle.stack.badge.play",
        isDefault: false
    )

    static let fallbackPlaylistOption = QueuePlaylistCatalog.Item(
        id: "",
        title: "Up Next",
        symbolName: "calendar.day.timeline.leading",
        isDefault: true
    )

    func placeholder(in context: Context) -> QueueTimelineEntry {
        QueueTimelineEntry(
            date: .now,
            snapshot: .empty,
            playlistID: "",
            playlistTitle: "Up Next",
            statusMessage: "Open Up Next to prepare widget data."
        )
    }

    func snapshot(for configuration: QueueConfigurationIntent, in context: Context) async -> QueueTimelineEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: QueueConfigurationIntent, in context: Context) async -> Timeline<QueueTimelineEntry> {
        let entry = entry(for: configuration)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }

    private func entry(for configuration: QueueConfigurationIntent) -> QueueTimelineEntry {
        let catalog = Self.loadCatalog()
        let options = Self.playlistOptions(from: catalog)
        let requestedPlaylistID = configuration.playlist?.id
        var selectedPlaylist: QueuePlaylistCatalog.Item
        if let requestedPlaylistID,
           requestedPlaylistID != Self.currentPlaylistOptionID,
           let match = options.first(where: { $0.id == requestedPlaylistID }) {
            selectedPlaylist = match
        } else {
            selectedPlaylist = Self.selectedPlaylistOption() ?? Self.defaultPlaylistOption() ?? Self.fallbackPlaylistOption
        }

        let selectedSnapshot = loadSnapshot(for: selectedPlaylist.id)
        let legacySnapshot = loadSnapshot(for: "")
        var snapshot = selectedSnapshot
            ?? legacySnapshot
            ?? .empty
        var statusMessage: String?
        if selectedSnapshot == nil, legacySnapshot == nil {
            statusMessage = catalog == nil
                ? "Open Up Next to prepare widget data."
                : "No widget data for this playlist yet."
        }

        if requestedPlaylistID != Self.currentPlaylistOptionID,
           selectedPlaylist.isDefault,
           snapshot.items.isEmpty,
           let currentPlaylist = Self.selectedPlaylistOption(),
           currentPlaylist.id != selectedPlaylist.id,
           let currentSnapshot = loadSnapshot(for: currentPlaylist.id),
           currentSnapshot.items.isEmpty == false {
            selectedPlaylist = currentPlaylist
            snapshot = currentSnapshot
            statusMessage = nil
        }

        return QueueTimelineEntry(
            date: .now,
            snapshot: snapshot,
            playlistID: selectedPlaylist.id,
            playlistTitle: selectedPlaylist.title,
            statusMessage: statusMessage
        )
    }

    static func loadPlaylistOptions() -> [QueuePlaylistCatalog.Item] {
        playlistOptions(from: loadCatalog())
    }

    static func playlistOptions(from catalog: QueuePlaylistCatalog?) -> [QueuePlaylistCatalog.Item] {
        guard let catalog else {
            return [fallbackPlaylistOption]
        }

        if catalog.playlists.isEmpty {
            return [fallbackPlaylistOption]
        }

        return catalog.playlists
    }

    static func defaultPlaylistOption() -> QueuePlaylistCatalog.Item? {
        let options = loadPlaylistOptions()
        return options.first(where: \.isDefault) ?? options.first
    }

    static func selectedPlaylistOption() -> QueuePlaylistCatalog.Item? {
        guard let catalog = loadCatalog(),
              let selectedPlaylistID = catalog.selectedPlaylistID,
              selectedPlaylistID.isEmpty == false
        else {
            return nil
        }

        return catalog.playlists.first(where: { $0.id == selectedPlaylistID })
    }

    private static func loadCatalog() -> QueuePlaylistCatalog? {
        guard
            let url = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
                .appendingPathComponent(catalogFileName),
            let data = try? Data(contentsOf: url)
        else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(QueuePlaylistCatalog.self, from: data)
    }

    private func loadSnapshot(for playlistID: String) -> QueueSnapshot? {
        let fileName: String
        if playlistID.isEmpty {
            fileName = Self.legacyFileName
        } else {
            fileName = "\(Self.snapshotFilePrefix)\(playlistID).json"
        }

        guard
            let url = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)?
                .appendingPathComponent(fileName),
            let data = try? Data(contentsOf: url)
        else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(QueueSnapshot.self, from: data)
    }
}

private extension QueueSnapshot {
    static var empty: QueueSnapshot {
        QueueSnapshot(
            generatedAt: .now,
            totalItemCount: 0,
            currentIndex: nil,
            items: []
        )
    }

    var currentItem: Item? {
        items.first(where: \.isCurrent)
    }

    var upcomingItems: [Item] {
        items.filter { $0.isCurrent == false }
    }
}

struct PlayNextQueueWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "PlayNextQueueWidget", intent: QueueConfigurationIntent.self, provider: QueueProvider()) { entry in
            PlayNextQueueWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Play Next Queue")
        .description("Shows episodes from a selected playlist.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryRectangular,
        ])
    }
}

private struct PlayNextQueueWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: QueueTimelineEntry

    var body: some View {
        switch family {
        case .systemSmall:
            smallView
        case .systemMedium:
            listView(limit: 2, showsCurrent: true, spacing: 6)
        case .systemLarge:
            listView(limit: 6, showsCurrent: true)
        case .accessoryRectangular:
            accessoryView
        default:
            listView(limit: 3, showsCurrent: true)
        }
    }

    private var widgetURL: URL? {
        guard var components = URLComponents(string: "upnext://playlist") else {
            return URL(string: "upnext://playlist")
        }

        if entry.playlistID.isEmpty == false {
            components.queryItems = [URLQueryItem(name: "playlistID", value: entry.playlistID)]
        }

        return components.url
    }

    private var smallView: some View {
        let primaryItem = entry.snapshot.currentItem ?? entry.snapshot.upcomingItems.first
        let secondaryItem = entry.snapshot.currentItem != nil
            ? entry.snapshot.upcomingItems.first
            : entry.snapshot.upcomingItems.dropFirst().first

        return VStack(alignment: .leading, spacing: 8) {
            widgetHeader

            if let primaryItem {
                QueueLine(
                    item: primaryItem,
                    style: primaryItem.isCurrent ? .current : .upNext
                )
            } else {
                emptyState
            }

            if let secondaryItem {
                Divider()
                QueueLine(item: secondaryItem, style: .upNext)
            }
        }
        .widgetURL(widgetURL)
    }

    private func listView(limit: Int, showsCurrent: Bool, spacing: CGFloat = 8) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            widgetHeader

            if entry.snapshot.items.isEmpty {
                emptyState
            } else {
                if showsCurrent, let current = entry.snapshot.currentItem {
                    QueueLine(item: current, style: .current)
                }

                ForEach(Array(entry.snapshot.upcomingItems.prefix(limit))) { item in
                    QueueLine(item: item, style: .upNext)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(widgetURL)
    }

    private var accessoryView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.playlistTitle)
                .font(.caption2)
                .foregroundStyle(Color.upNextAccent)
                .lineLimit(1)

            if let first = entry.snapshot.upcomingItems.first ?? entry.snapshot.currentItem {
                HStack(spacing: 6) {
                    QueueCover(url: first.coverURL, fileName: first.coverFileName, size: 22)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(first.title)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .lineLimit(1)

                        if let podcast = first.podcast, podcast.isEmpty == false {
                            Text(podcast)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } else {
                Text(entry.statusMessage ?? "Queue is empty")
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .widgetURL(widgetURL)
    }

    private var widgetHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.caption)
                .foregroundStyle(Color.upNextAccent)
            Text(entry.playlistTitle)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
                .foregroundStyle(Color.upNextAccent)
            Spacer(minLength: 0)
            if let progressText {
                Text(progressText)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
        }
        .padding(.top, 1)
    }

    private var progressText: String? {
        guard let total = entry.snapshot.totalItemCount, total > 0 else {
            return nil
        }

        if let currentIndex = entry.snapshot.currentIndex {
            return "\(currentIndex + 1)/\(total)"
        }

        return "\(total) left"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.statusMessage ?? "Queue is empty")
                .font(.subheadline)
                .fontWeight(.semibold)
            if entry.statusMessage == nil {
                Text("Add episodes in the app to see them here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }
}

private struct QueueLine: View {
    enum Style {
        case current
        case upNext
    }

    let item: QueueSnapshot.Item
    let style: Style

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            QueueCover(
                url: item.coverURL,
                fileName: item.coverFileName,
                size: 26,
                fallbackSystemName: style == .current ? "play.circle.fill" : "text.line.first.and.arrowtriangle.forward",
                fallbackColor: style == .current ? .upNextAccent : .secondary
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(style == .current ? .semibold : .regular)
                    .foregroundStyle(style == .current ? Color.upNextAccent : Color.primary)
                    .lineLimit(1)

                if let supportingText = supportingText, supportingText.isEmpty == false {
                    Text(supportingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var supportingText: String? {
        switch style {
        case .current:
            return item.podcast ?? item.subtitle
        case .upNext:
            return item.podcast ?? item.subtitle
        }
    }
}

private struct QueueCover: View {
    let url: URL?
    let fileName: String?
    let size: CGFloat
    var fallbackSystemName: String = "text.line.first.and.arrowtriangle.forward"
    var fallbackColor: Color = .secondary

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.quaternary)

            if let localImage {
                localImage
                    .resizable()
                    .scaledToFill()
            } else if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallbackIcon
                    }
                }
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var localImage: Image? {
        #if canImport(UIKit)
        guard let fileName,
              let url = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: QueueProvider.appGroupID)?
                .appendingPathComponent(fileName),
              let image = UIImage(contentsOfFile: url.path)
        else { return nil }

        return Image(uiImage: image)
        #else
        return nil
        #endif
    }

    private var fallbackIcon: some View {
        Image(systemName: fallbackSystemName)
            .font(.system(size: max(size * 0.48, 10), weight: .medium))
            .foregroundStyle(fallbackColor)
    }
}

#Preview(as: .systemMedium) {
    PlayNextQueueWidget()
} timeline: {
    QueueTimelineEntry(
        date: .now,
        snapshot: .empty,
        playlistID: "",
        playlistTitle: "Up Next",
        statusMessage: "Open Up Next to prepare widget data."
    )
}
