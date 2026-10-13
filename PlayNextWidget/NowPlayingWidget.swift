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
    let playbackRate: Double?
    let title: String?
    let podcastTitle: String?
    let coverFileName: String?
}

private struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot?

    static var empty: NowPlayingEntry { .init(date: .now, snapshot: nil) }
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
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: QueueProvider.appGroupID)?
            .appendingPathComponent("play-next-widget-playback-v1.json"),
              let data = try? Data(contentsOf: url) else {
            return .empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return NowPlayingEntry(date: .now, snapshot: try? decoder.decode(NowPlayingSnapshot.self, from: data))
    }
}

struct UpNextNowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UpNextNowPlayingWidget", provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Now Playing")
        .description("Continue listening and control your podcast.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

private struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry

    private var snapshot: NowPlayingSnapshot? { entry.snapshot }

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
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .tint(.primary)
                    .accessibilityLabel("Episode progress")
                transportButton(size: 30)
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
                HStack(alignment: .center, spacing: 9) {
                    progressTrack
                    transportButton(size: 30)
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
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }

    private var localArtwork: Image? {
        #if canImport(UIKit)
        guard let filename = snapshot?.coverFileName,
              let url = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: QueueProvider.appGroupID)?
                .appendingPathComponent(filename),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: image)
        #else
        return nil
        #endif
    }

    private func episodeText(titleLineLimit: Int, showMetadata: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                if geometry.size.width >= 76 {
                    Text(snapshot?.title ?? "Play Up Next")
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
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if showMetadata, snapshot?.episodeID == nil {
                Text("Your next episode is ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if showMetadata, let remaining = remainingText {
                Text(remaining)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var progressTrack: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress)
                .tint(.primary)
                .accessibilityLabel("Episode progress")
            HStack {
                Text(snapshot?.isPlaying == true ? "Now Playing" : (snapshot?.episodeID == nil ? "Up Next" : "Paused"))
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func transportButton(size: CGFloat) -> some View {
        Button(intent: WidgetPlayPauseIntent()) {
            WidgetPlaybackControl(
                progress: progress,
                isPlaying: snapshot?.isPlaying == true,
                size: size - 8
            )
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(snapshot?.isPlaying == true ? "Pause playback" : "Play or resume playback")
        .accessibilityHint(snapshot?.episodeID == nil ? "Starts the first episode in Up Next." : "Controls the current episode.")
    }

    private var progress: Double {
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
