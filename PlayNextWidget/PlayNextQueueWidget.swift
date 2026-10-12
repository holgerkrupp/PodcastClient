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
        let progress: Double?
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
    let isPlaying: Bool
    let playbackProgress: Double?
}

private struct QueuePlaybackState: Decodable {
    let isPlaying: Bool
    let positionSeconds: Double?
    let durationSeconds: Double?

    var progress: Double? {
        guard let positionSeconds, let durationSeconds,
              positionSeconds.isFinite, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        return min(max(positionSeconds / durationSeconds, 0), 1)
    }
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
            statusMessage: "Open Up Next to prepare widget data.",
            isPlaying: false,
            playbackProgress: nil
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

        let playbackState = Self.loadPlaybackState()
        return QueueTimelineEntry(
            date: .now,
            snapshot: snapshot,
            playlistID: selectedPlaylist.id,
            playlistTitle: selectedPlaylist.title,
            statusMessage: statusMessage,
            isPlaying: playbackState?.isPlaying ?? false,
            playbackProgress: playbackState?.progress
        )
    }

    private static func loadPlaybackState() -> QueuePlaybackState? {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("play-next-widget-playback-v1.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(QueuePlaybackState.self, from: data)
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
        #if os(macOS)
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge
        ])
        #else
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryRectangular
        ])
        #endif
        .contentMarginsDisabled()
    }
}

private struct PlayNextQueueWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: QueueTimelineEntry

    var body: some View {
        switch family {
        case .systemSmall:
            smallQueueView
        case .systemMedium:
            mediumQueueView
        case .systemLarge:
            largeQueueView
        case .accessoryRectangular:
            accessoryView
        default:
            smallQueueView
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

    private var smallQueueView: some View {
        VStack(alignment: .leading, spacing: 8) {
            widgetHeader.padding(.horizontal, 12).padding(.top, 10)
            if let featuredItem {
                QueueFeature(item: featuredItem, playlistID: entry.playlistID, compact: true, isPlaying: entry.isPlaying, playbackProgress: entry.playbackProgress)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                emptyState.padding(12)
            }
        }
    }

    private var mediumQueueView: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                widgetHeader.padding(.horizontal, 14).padding(.top, 12)
                if let mediumFeaturedItem {
                    QueueFeature(item: mediumFeaturedItem, playlistID: entry.playlistID, compact: true, isPlaying: entry.isPlaying, playbackProgress: entry.playbackProgress)
                        .padding(.horizontal, 14)
                } else {
                    emptyState.padding(.horizontal, 14)
                }
                Spacer(minLength: 10)
            }
            if let mediumFeaturedItem {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(entry.snapshot.upcomingItems.filter { $0.id != mediumFeaturedItem.id }.prefix(2))) { item in
                        QueueLine(item: item, playlistID: entry.playlistID, isPlaying: entry.isPlaying, playbackProgress: entry.playbackProgress)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 18)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var largeQueueView: some View {
        VStack(alignment: .leading, spacing: 8) {
            widgetHeader.padding(.horizontal, 16).padding(.top, 12)
            if let largeFeaturedItem {
                QueueFeature(item: largeFeaturedItem, playlistID: entry.playlistID, compact: false, isPlaying: entry.isPlaying, playbackProgress: entry.playbackProgress)
                    .padding(.horizontal, 16)
                ForEach(Array(entry.snapshot.upcomingItems.filter { $0.id != largeFeaturedItem.id }.prefix(3))) { item in
                    QueueLine(item: item, playlistID: entry.playlistID, isPlaying: entry.isPlaying, playbackProgress: entry.playbackProgress)
                        .padding(.horizontal, 16)
                }
            } else {
                emptyState.padding(.horizontal, 16)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 12)
    }

    private var featuredItem: QueueSnapshot.Item? {
        entry.snapshot.upcomingItems.first ?? entry.snapshot.currentItem
    }

    private var mediumFeaturedItem: QueueSnapshot.Item? {
        entry.snapshot.currentItem ?? featuredItem
    }

    private var largeFeaturedItem: QueueSnapshot.Item? {
        entry.snapshot.currentItem ?? featuredItem
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
                .widgetAccentable()
            Text(entry.playlistTitle)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
                .foregroundStyle(Color.upNextAccent)
                .widgetAccentable()
            Spacer(minLength: 0)
            if let progressText {
                Text(progressText)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
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

private struct QueueFeature: View {
    let item: QueueSnapshot.Item
    let playlistID: String
    let compact: Bool
    let isPlaying: Bool
    let playbackProgress: Double?

    var body: some View {
        HStack(spacing: 10) {
            QueueCover(url: item.coverURL, fileName: item.coverFileName, size: compact ? 72 : 90)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.isCurrent ? "Now Playing" : "Up Next")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.upNextAccent)
                    .widgetAccentable()
                if let detailURL {
                    Link(destination: detailURL) {
                        label
                    }
                    .buttonStyle(.plain)
                } else {
                    label
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    ProgressView(value: progress).tint(Color.upNextAccent)
                    QueuePlaybackButton(item: item, size: 40, isPlaying: isPlaying, playbackProgress: playbackProgress)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geometry in
                if geometry.size.width >= 76 {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(compact ? 1 : 3)
                }
            }
            .frame(height: compact ? 18 : 54)
            if let podcast = item.podcast ?? item.subtitle, podcast.isEmpty == false {
                Text(podcast).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var progress: Double {
        if item.isCurrent, let playbackProgress {
            return min(max(playbackProgress, 0), 1)
        }
        guard let value = item.progress, value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private var detailURL: URL? {
        guard item.id.hasPrefix("private-") == false else { return nil }
        guard var components = URLComponents(string: "upnext://episode") else { return nil }
        var queryItems = [URLQueryItem(name: "url", value: item.id)]
        if playlistID.isEmpty == false {
            queryItems.append(URLQueryItem(name: "playlistID", value: playlistID))
        }
        components.queryItems = queryItems
        return components.url
    }
}

private struct QueueLine: View {
    let item: QueueSnapshot.Item
    let playlistID: String
    let isPlaying: Bool
    let playbackProgress: Double?

    var body: some View {
        HStack(spacing: 9) {
            if let detailURL {
                Link(destination: detailURL) { episodeLabel }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                episodeLabel
            }
            QueuePlaybackButton(item: item, size: 40, isPlaying: isPlaying, playbackProgress: playbackProgress)
        }
        .padding(.vertical, 3)
    }

    private var episodeLabel: some View {
        HStack(spacing: 9) {
            QueueCover(url: item.coverURL, fileName: item.coverFileName, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                GeometryReader { geometry in
                    if geometry.size.width >= 76 {
                        Text(item.title)
                            .font(.subheadline.weight(item.isCurrent ? .semibold : .regular))
                            .lineLimit(1)
                    }
                }
                .frame(height: 18)
                if let podcast = item.podcast ?? item.subtitle, podcast.isEmpty == false {
                    Text(podcast).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var detailURL: URL? {
        guard item.id.hasPrefix("private-") == false else { return nil }
        guard var components = URLComponents(string: "upnext://episode") else { return nil }
        var queryItems = [URLQueryItem(name: "url", value: item.id)]
        if playlistID.isEmpty == false {
            queryItems.append(URLQueryItem(name: "playlistID", value: playlistID))
        }
        components.queryItems = queryItems
        return components.url
    }
}

private struct QueuePlaybackButton: View {
    let item: QueueSnapshot.Item
    let size: CGFloat
    let isPlaying: Bool
    let playbackProgress: Double?

    @ViewBuilder
    var body: some View {
        if item.isCurrent {
            Button(intent: WidgetPlayPauseIntent()) {
                WidgetPlaybackProgressRing(
                    progress: playbackProgress ?? 0,
                    isPlaying: isPlaying,
                    size: 30
                )
                    .frame(width: 40, height: 40)
            }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause current episode" : "Play current episode")
        } else if item.id.hasPrefix("private-") == false {
            Button(intent: WidgetPlayEpisodeIntent(episodeID: item.id)) { icon("play.fill") }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(item.title)")
        } else {
            EmptyView()
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: size, height: size)
            .contentShape(Rectangle())
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
                    .widgetAccentedRenderingMode(.desaturated)
                    .scaledToFill()
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
        statusMessage: "Open Up Next to prepare widget data.",
        isPlaying: false,
        playbackProgress: nil
    )
}
