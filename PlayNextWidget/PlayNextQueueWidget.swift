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

private struct QueueTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: QueueSnapshot
}

private struct QueueProvider: TimelineProvider {
    private let appGroupID = "group.de.holgerkrupp.PodcastClient"
    private let fileName = "play-next-widget.json"

    func placeholder(in context: Context) -> QueueTimelineEntry {
        QueueTimelineEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (QueueTimelineEntry) -> Void) {
        completion(QueueTimelineEntry(date: .now, snapshot: loadSnapshot() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QueueTimelineEntry>) -> Void) {
        let entry = QueueTimelineEntry(date: .now, snapshot: loadSnapshot() ?? .placeholder)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func loadSnapshot() -> QueueSnapshot? {
        guard
            let url = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
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
        StaticConfiguration(kind: "PlayNextQueueWidget", provider: QueueProvider()) { entry in
            PlayNextQueueWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Play Next Queue")
        .description("Shows the next items waiting in your Up Next playlist.")
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
        .widgetURL(URL(string: "upnext://playlist"))
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
        .widgetURL(URL(string: "upnext://playlist"))
    }

    private var accessoryView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Up Next")
                .font(.caption2)
                .foregroundStyle(.secondary)

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
        .widgetURL(URL(string: "upnext://playlist"))
    }

    private var widgetHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.caption)
            Text("Up Next")
                .font(.caption)
                .fontWeight(.semibold)
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
    QueueTimelineEntry(date: .now, snapshot: .placeholder)
}
