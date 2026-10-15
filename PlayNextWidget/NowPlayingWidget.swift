import AppIntents
import SwiftUI
import WidgetKit

#if canImport(UIKit)
import UIKit
#endif

private struct NowPlayingSnapshot: Decodable {
    let schemaVersion: Int
    let updatedAt: Date
    let episodeID: String?
    let isPlaying: Bool
    let positionSeconds: Double?
    let durationSeconds: Double?
    let progressFraction: Double?
    let playbackRate: Double?
    let title: String?
    let podcastTitle: String?
    let coverFileName: String?
    let skipBackSymbol: String?
    let skipForwardSymbol: String?
    let skipBackSeconds: Int?
    let skipForwardSeconds: Int?
}

private struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot?
    let visualStyle: String

    static var empty: NowPlayingEntry {
        .init(date: .now, snapshot: nil, visualStyle: WidgetVisualDesign.selectedStyle)
    }
}

private struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry { .empty }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .never))
    }

    private func entry() -> NowPlayingEntry {
        let playbackSnapshot: NowPlayingSnapshot? = {
            guard let url = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: QueueProvider.appGroupID)?
                .appendingPathComponent("play-next-widget-playback-v1.json"),
                  let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(NowPlayingSnapshot.self, from: data)
        }()

        let hasPlaybackTitle = playbackSnapshot?.title?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let snapshot = hasPlaybackTitle ? playbackSnapshot : (queuedEpisodeSnapshot() ?? playbackSnapshot)
        return NowPlayingEntry(date: .now, snapshot: snapshot, visualStyle: WidgetVisualDesign.selectedStyle)
    }

    private func queuedEpisodeSnapshot() -> NowPlayingSnapshot? {
        guard let directory = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: QueueProvider.appGroupID) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalogURL = directory.appendingPathComponent(QueueProvider.catalogFileName)
        let catalog = (try? Data(contentsOf: catalogURL)).flatMap {
            try? decoder.decode(QueuePlaylistCatalog.self, from: $0)
        }
        let playlistIDs = ([catalog?.selectedPlaylistID]
            + [catalog?.playlists.first(where: \.isDefault)?.id]
            + (catalog?.playlists.map(\.id) ?? []))
            .compactMap { $0 }
        let filenames = playlistIDs.map { "\(QueueProvider.snapshotFilePrefix)\($0).json" }
            + [QueueProvider.legacyFileName]
        var seenFilenames = Set<String>()

        for filename in filenames where seenFilenames.insert(filename).inserted {
            let url = directory.appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: url),
                  let queue = try? decoder.decode(QueueSnapshot.self, from: data),
                  let item = queue.items.first(where: \.isCurrent)
                    ?? queue.items.first(where: { $0.isCurrent == false })
                    ?? queue.items.first,
                  item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { continue }

            return NowPlayingSnapshot(
                schemaVersion: 1,
                updatedAt: queue.generatedAt,
                episodeID: nil,
                isPlaying: false,
                positionSeconds: nil,
                durationSeconds: nil,
                progressFraction: item.progress,
                playbackRate: nil,
                title: item.title,
                podcastTitle: item.podcast ?? item.subtitle,
                coverFileName: item.coverFileName,
                skipBackSymbol: nil,
                skipForwardSymbol: nil,
                skipBackSeconds: nil,
                skipForwardSeconds: nil
            )
        }
        return nil
    }
}

struct UpNextNowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UpNextNowPlayingWidget", provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .widgetVisualDesign(
                    style: entry.visualStyle,
                    artwork: WidgetVisualDesign.artwork(named: entry.snapshot?.coverFileName)
                )
                .containerBackground(for: .widget) {
                    WidgetVisualDesignBackground(
                        style: entry.visualStyle,
                        artwork: WidgetVisualDesign.artwork(named: entry.snapshot?.coverFileName)
                    )
                }
        }
        .configurationDisplayName("Now Playing")
        .description("Continue listening and control your podcast.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

private struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetDesignPalette) private var palette
    let entry: NowPlayingEntry

    private var snapshot: NowPlayingSnapshot? { entry.snapshot }

    private var displayTitle: String? {
        guard let title = snapshot?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              title.isEmpty == false else { return nil }
        return title
    }

    var body: some View {
        Group {
            if family == .systemMedium {
                mediumLayout
            } else {
                smallLayout
            }
        }
        .widgetURL(episodeURL)
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 4) {
            artwork(size: 58)
            episodeText(titleLineLimit: 1, showMetadata: false)
            HStack(spacing: 2) {
                skipBackButton(size: 36)
                transportButton(size: 30, hitTarget: 36)
                skipForwardButton(size: 36)
            }
        }
        .padding(10)
    }

    private var mediumLayout: some View {
        HStack(spacing: 14) {
            artwork(size: 132)
                .frame(maxWidth: 132, maxHeight: 132)
            VStack(alignment: .leading, spacing: 7) {
                episodeText(titleLineLimit: 3, showMetadata: true)
                Spacer(minLength: 0)
                HStack(alignment: .center, spacing: 5) {
                    skipBackButton(size: 40)
                    transportButton(size: 30)
                    skipForwardButton(size: 40)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }

    private func artwork(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary)
            if let image = localArtwork {
                image
                    .resizable()
                    .widgetAccentedRenderingMode(.fullColor)
                    .scaledToFill()
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.3, weight: .medium))
                    .foregroundStyle(palette.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }

    private var localArtworkImage: WidgetPlatformImage? {
        WidgetVisualDesign.artwork(named: snapshot?.coverFileName)
    }

    private var localArtwork: Image? {
        localArtworkImage.map { WidgetVisualDesign.image($0) }
    }

    private func episodeText(titleLineLimit: Int, showMetadata: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                if geometry.size.width >= 76 {
                    Text(displayTitle ?? "Nothing queued")
                        .font(family == .systemSmall ? .subheadline : .headline)
                        .fontWeight(.semibold)
                        .lineLimit(titleLineLimit)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(height: family == .systemSmall ? 18 : 60)
            if showMetadata, let podcast = snapshot?.podcastTitle, podcast.isEmpty == false {
                Text(podcast)
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            } else if showMetadata, displayTitle == nil {
                Text("Add episodes to Up Next")
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }
            if showMetadata, let remaining = remainingText {
                Text(remaining)
                    .font(.caption2)
                    .foregroundStyle(palette.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func transportButton(size: CGFloat, hitTarget: CGFloat = 44) -> some View {
        Button(intent: WidgetPlayPauseIntent()) {
            WidgetPlaybackControl(
                progress: progress,
                isPlaying: snapshot?.isPlaying == true,
                size: size - 8
            )
                .frame(width: hitTarget, height: hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(snapshot?.isPlaying == true ? "Pause playback" : "Play or resume playback")
        .accessibilityHint(snapshot?.episodeID == nil ? "Starts the first episode in Up Next." : "Controls the current episode.")
    }

    private func skipBackButton(size: CGFloat) -> some View {
        Button(intent: WidgetSkipBackIntent()) {
            Image(systemName: snapshot?.skipBackSymbol ?? "15.arrow.trianglehead.counterclockwise")
                .font(.system(size: 17, weight: .medium))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Skip back \(snapshot?.skipBackSeconds ?? 15) seconds")
    }

    private func skipForwardButton(size: CGFloat) -> some View {
        Button(intent: WidgetSkipForwardIntent()) {
            Image(systemName: snapshot?.skipForwardSymbol ?? "30.arrow.trianglehead.clockwise")
                .font(.system(size: 17, weight: .medium))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Skip forward \(snapshot?.skipForwardSeconds ?? 30) seconds")
    }

    private var progress: Double {
        if let fraction = snapshot?.progressFraction, fraction.isFinite {
            return min(max(fraction, 0), 1)
        }
        guard let position = snapshot?.positionSeconds,
              let duration = snapshot?.durationSeconds,
              position.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    private var remainingText: String? {
        guard let position = snapshot?.positionSeconds,
              let duration = snapshot?.durationSeconds,
              position.isFinite, duration.isFinite, duration > 0 else { return nil }
        let seconds = max(0, Int((duration - position) / max(snapshot?.playbackRate ?? 1, 0.1)))
        return "\(Self.clock(seconds)) left"
    }

    private var episodeURL: URL? {
        guard let id = snapshot?.episodeID,
              var components = URLComponents(string: "upnext://episode") else { return nil }
        components.queryItems = [URLQueryItem(name: "url", value: id)]
        return components.url
    }

    private static func clock(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }
}

#Preview(as: .systemSmall) {
    UpNextNowPlayingWidget()
} timeline: {
    NowPlayingEntry.empty
}

#Preview(as: .systemMedium) {
    UpNextNowPlayingWidget()
} timeline: {
    NowPlayingEntry.empty
}
