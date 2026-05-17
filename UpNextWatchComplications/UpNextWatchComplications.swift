import SwiftUI
import WidgetKit

private struct WatchComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchComplicationSnapshot
}

private struct WatchComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchComplicationEntry {
        WatchComplicationEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchComplicationEntry) -> Void) {
        completion(WatchComplicationEntry(date: .now, snapshot: WatchComplicationStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchComplicationEntry>) -> Void) {
        let entry = WatchComplicationEntry(date: .now, snapshot: WatchComplicationStore.load())
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct WatchAppLauncherComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchAppLauncherComplication", provider: WatchComplicationProvider()) { entry in
            WatchAppLauncherView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Up Next")
        .description("Launch Up Next from your watch face.")
        .supportedFamilies(watchComplicationFamilies)
    }
}

struct WatchEpisodeProgressComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchEpisodeProgressComplication", provider: WatchComplicationProvider()) { entry in
            WatchEpisodeProgressView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Episode Progress")
        .description("Shows the current episode and listening progress.")
        .supportedFamilies(watchComplicationFamilies)
    }
}

struct WatchPlaylistRemainingComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchPlaylistRemainingComplication", provider: WatchComplicationProvider()) { entry in
            WatchPlaylistRemainingView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Playlist Remaining")
        .description("Shows how many items remain in the selected playlist.")
        .supportedFamilies(watchComplicationFamilies)
    }
}

struct WatchSyncStatusComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchSyncStatusComplication", provider: WatchComplicationProvider()) { entry in
            WatchSyncStatusView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Watch Sync")
        .description("Shows inbox, downloads, and active transfer progress.")
        .supportedFamilies(watchComplicationFamilies)
    }
}

private let watchComplicationFamilies: [WidgetFamily] = [
    .accessoryCircular,
    .accessoryCorner,
    .accessoryInline,
    .accessoryRectangular,
]

private struct WatchAppLauncherView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WatchComplicationSnapshot

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label("Up Next", systemImage: "play.circle.fill")
            case .accessoryRectangular:
                HStack(spacing: 7) {
                    UpNextGlyph()
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Up Next")
                            .font(.headline)
                        Text(snapshot.currentTitle ?? snapshot.nextTitle ?? "Open player")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            case .accessoryCorner:
                UpNextGlyph()
                    .widgetLabel {
                        Text(snapshot.isPlaying ? "Playing" : "Up Next")
                    }
            default:
                UpNextGlyph()
            }
        }
        .widgetURL(URL(string: "upnext://watch"))
    }
}

private struct WatchEpisodeProgressView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WatchComplicationSnapshot

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                Gauge(value: snapshot.playbackProgress ?? 0) {
                    Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                } currentValueLabel: {
                    Text(snapshot.progressPercentText)
                        .font(.system(size: 12, weight: .semibold))
                        .minimumScaleFactor(0.65)
                }
                .gaugeStyle(.accessoryCircular)
                .tint(.orange)
            case .accessoryCorner:
                Gauge(value: snapshot.playbackProgress ?? 0) {
                    Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                }
                .gaugeStyle(.accessoryCircular)
                .widgetLabel {
                    Text(snapshot.currentTitle ?? "No episode")
                }
            case .accessoryInline:
                Label(snapshot.inlineProgressText, systemImage: snapshot.isPlaying ? "pause.fill" : "play.fill")
            default:
                HStack(spacing: 7) {
                    Gauge(value: snapshot.playbackProgress ?? 0) {
                        Image(systemName: "play.fill")
                    } currentValueLabel: {
                        Text(snapshot.progressPercentText)
                            .font(.caption2.weight(.semibold))
                            .minimumScaleFactor(0.65)
                    }
                    .gaugeStyle(.accessoryCircular)
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.currentTitle ?? "Nothing playing")
                            .font(.headline)
                            .lineLimit(1)
                        Text(snapshot.currentChapterTitle ?? snapshot.currentPodcast ?? snapshot.timeRemainingText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .widgetURL(URL(string: snapshot.currentEpisodeID == nil ? "upnext://watch" : "upnext://player"))
    }
}

private struct WatchPlaylistRemainingView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WatchComplicationSnapshot

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                VStack(spacing: 0) {
                    Text("\(snapshot.remainingCount)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.caption2)
                }
                .widgetAccentable()
            case .accessoryCorner:
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .widgetLabel {
                        Text("\(snapshot.remainingCount) left")
                    }
            case .accessoryInline:
                Label("\(snapshot.remainingCount) left in \(snapshot.selectedPlaylistTitle)", systemImage: "list.bullet")
            default:
                HStack(spacing: 8) {
                    CountBadge(value: snapshot.remainingCount, caption: "left")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.selectedPlaylistTitle)
                            .font(.headline)
                            .lineLimit(1)
                        Text(snapshot.nextTitle.map { "Next: \($0)" } ?? "Queue is empty")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .widgetURL(URL(string: "upnext://playlist"))
    }
}

private struct WatchSyncStatusView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WatchComplicationSnapshot

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                Gauge(value: snapshot.highestTransferProgress ?? 0) {
                    Image(systemName: syncSymbol)
                } currentValueLabel: {
                    Text("\(snapshot.downloadedCount)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                }
                .gaugeStyle(.accessoryCircular)
                .tint(.teal)
            case .accessoryCorner:
                Image(systemName: syncSymbol)
                    .widgetLabel {
                        Text(syncLabel)
                    }
            case .accessoryInline:
                Label(syncLabel, systemImage: syncSymbol)
            default:
                HStack(spacing: 8) {
                    Image(systemName: syncSymbol)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(syncLabel)
                            .font(.headline)
                            .lineLimit(1)
                        Text("\(snapshot.inboxCount) inbox / \(snapshot.downloadedCount) on watch")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .widgetURL(URL(string: "upnext://watch-sync"))
    }

    private var syncSymbol: String {
        snapshot.activeTransferCount > 0 ? "arrow.down.circle.fill" : "checkmark.circle.fill"
    }

    private var syncLabel: String {
        if snapshot.activeTransferCount > 0 {
            return "\(snapshot.activeTransferCount) syncing"
        }

        return "\(snapshot.downloadedCount) downloaded"
    }
}

private struct UpNextGlyph: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(.orange.gradient)
            Image(systemName: "play.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: 1)
        }
        .widgetAccentable()
    }
}

private struct CountBadge: View {
    let value: Int
    let caption: String

    var body: some View {
        VStack(spacing: 0) {
            Text("\(value)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.55)
            Text(caption)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 38, height: 38)
        .background(.quaternary, in: Circle())
    }
}

private extension WatchComplicationSnapshot {
    static var preview: WatchComplicationSnapshot {
        WatchComplicationSnapshot(
            generatedAt: .now,
            selectedPlaylistTitle: "Up Next",
            currentEpisodeID: "preview",
            currentTitle: "Building Better Apps",
            currentPodcast: "Swift by Sundell",
            currentChapterTitle: "WidgetKit",
            duration: 3600,
            playPosition: 1740,
            isPlaying: true,
            playlistTotalCount: 8,
            currentIndex: 2,
            nextTitle: "Designing for watchOS",
            nextPodcast: "Under the Radar",
            inboxCount: 5,
            downloadedCount: 3,
            activeTransferCount: 1,
            highestTransferProgress: 0.42
        )
    }

    var progressPercentText: String {
        guard let playbackProgress else { return "0%" }
        return "\(Int((playbackProgress * 100).rounded()))%"
    }

    var inlineProgressText: String {
        guard let currentTitle else { return "Nothing playing" }
        return "\(progressPercentText) \(currentTitle)"
    }

    var timeRemainingText: String {
        guard let duration, let playPosition else { return "Ready to play" }
        let remaining = max(duration - playPosition, 0)
        return "\(Self.formatDuration(remaining)) left"
    }

    static func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = max(Int(seconds.rounded() / 60), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        return "\(minutes)m"
    }
}

#Preview("Progress", as: .accessoryRectangular) {
    WatchEpisodeProgressComplication()
} timeline: {
    WatchComplicationEntry(date: .now, snapshot: .preview)
}

#Preview("Playlist", as: .accessoryCircular) {
    WatchPlaylistRemainingComplication()
} timeline: {
    WatchComplicationEntry(date: .now, snapshot: .preview)
}
