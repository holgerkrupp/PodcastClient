import AppIntents
import SwiftUI
import WidgetKit

private struct QueueSnapshot: Codable {
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

private struct QueuePlaylistCatalog: Codable {
    struct Item: Codable, Identifiable, Hashable {
        let id: String
        let title: String
        let symbolName: String
        let isDefault: Bool
    }

    let generatedAt: Date
    let playlists: [Item]
}

private struct QueueTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: QueueSnapshot
    let playlistID: String
    let playlistTitle: String
}

private struct QueuePlaylistEntity: AppEntity, Identifiable, Hashable {
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

private struct QueuePlaylistQuery: EntityQuery {
    func entities(for identifiers: [QueuePlaylistEntity.ID]) async throws -> [QueuePlaylistEntity] {
        let optionsByID = Dictionary(uniqueKeysWithValues: QueueProvider.loadPlaylistOptions().map { ($0.id, $0) })
        return identifiers.compactMap { identifier in
            guard let option = optionsByID[identifier] else { return nil }
            return QueuePlaylistEntity(
                id: option.id,
                title: option.title,
                symbolName: option.symbolName
            )
        }
    }

    func suggestedEntities() async throws -> [QueuePlaylistEntity] {
        QueueProvider.loadPlaylistOptions().map { option in
            QueuePlaylistEntity(
                id: option.id,
                title: option.title,
                symbolName: option.symbolName
            )
        }
    }

    func defaultResult() async -> QueuePlaylistEntity? {
        QueueProvider.defaultPlaylistOption().map { option in
            QueuePlaylistEntity(
                id: option.id,
                title: option.title,
                symbolName: option.symbolName
            )
        }
    }
}

private struct QueueConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Playlist"
    static let description = IntentDescription("Choose which playlist this widget should show.")

    @Parameter(title: "Playlist")
    var playlist: QueuePlaylistEntity?
}

private struct QueueProvider: AppIntentTimelineProvider {
    static let appGroupID = "group.de.holgerkrupp.PodcastClient"
    static let legacyFileName = "play-next-widget.json"
    static let catalogFileName = "play-next-widget-playlists.json"
    static let snapshotFilePrefix = "play-next-widget-"

    static let fallbackPlaylistOption = QueuePlaylistCatalog.Item(
        id: "",
        title: "Up Next",
        symbolName: "calendar.day.timeline.leading",
        isDefault: true
    )

    func placeholder(in context: Context) -> QueueTimelineEntry {
        QueueTimelineEntry(
            date: .now,
            snapshot: .placeholder,
            playlistID: "",
            playlistTitle: "Up Next"
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
        let options = Self.loadPlaylistOptions()
        let selectedPlaylist: QueuePlaylistCatalog.Item
        if let selectedID = configuration.playlist?.id,
           let match = options.first(where: { $0.id == selectedID }) {
            selectedPlaylist = match
        } else {
            selectedPlaylist = Self.defaultPlaylistOption() ?? Self.fallbackPlaylistOption
        }

        let snapshot = loadSnapshot(for: selectedPlaylist.id)
            ?? loadSnapshot(for: "")
            ?? .placeholder

        return QueueTimelineEntry(
            date: .now,
            snapshot: snapshot,
            playlistID: selectedPlaylist.id,
            playlistTitle: selectedPlaylist.title
        )
    }

    static func loadPlaylistOptions() -> [QueuePlaylistCatalog.Item] {
        guard let catalog = loadCatalog() else {
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
    static var placeholder: QueueSnapshot {
        QueueSnapshot(
            generatedAt: .now,
            items: [
                .init(id: "current", title: "Current episode", subtitle: "Resume where you left off", podcast: "Up Next", isCurrent: true),
                .init(id: "next", title: "Next in queue", subtitle: "Queued for later", podcast: "Up Next", isCurrent: false),
                .init(id: "later", title: "Another episode", subtitle: "Ready to play", podcast: "Up Next", isCurrent: false),
            ]
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
            listView(limit: 3, showsCurrent: true)
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

    private func listView(limit: Int, showsCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let first = entry.snapshot.upcomingItems.first ?? entry.snapshot.currentItem {
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
            } else {
                Text("Queue is empty")
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
            Text(entry.playlistTitle)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Queue is empty")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text("Add episodes in the app to see them here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
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
        let iconStyle: AnyShapeStyle = style == .current
            ? AnyShapeStyle(.tint)
            : AnyShapeStyle(.secondary)

        HStack(alignment: .top, spacing: 8) {
            Image(systemName: style == .current ? "play.circle.fill" : "text.line.first.and.arrowtriangle.forward")
                .font(.caption)
                .foregroundStyle(iconStyle)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(style == .current ? .semibold : .regular)
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

#Preview(as: .systemMedium) {
    PlayNextQueueWidget()
} timeline: {
    QueueTimelineEntry(
        date: .now,
        snapshot: .placeholder,
        playlistID: "",
        playlistTitle: "Up Next"
    )
}
