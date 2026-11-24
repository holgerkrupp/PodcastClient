import Foundation

enum InboxGrouping: String, CaseIterable, Identifiable, Sendable {
    case none
    case podcast
    case day
    case week

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .podcast: "Podcast"
        case .day: "Day"
        case .week: "Week"
        }
    }
}

/// A value-only inbox snapshot. Grouping and cleanup operate on this shape so
/// the render path never asks SwiftData for another relationship per row.
struct InboxEpisodeProjection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let podcastKey: String
    let podcastTitle: String
    let publishedAt: Date?
    let remainingDuration: TimeInterval
    let isSavedForLater: Bool
    let isFavorite: Bool
    let isQueued: Bool
    let isDownloaded: Bool
    let hasPlaybackHistory: Bool

    var isProtectedFromCleanup: Bool {
        isSavedForLater
            || isFavorite
            || isQueued
            || isDownloaded
            || hasPlaybackHistory
    }
}

struct InboxEpisodeGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let episodes: [InboxEpisodeProjection]

    var remainingDuration: TimeInterval {
        episodes.reduce(0) { $0 + max(0, $1.remainingDuration) }
    }
}

extension InboxEpisodeProjection {
    static func groups(
        from episodes: [InboxEpisodeProjection],
        grouping: InboxGrouping,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [InboxEpisodeGroup] {
        guard grouping != .none else {
            return [InboxEpisodeGroup(id: "all", title: "All Episodes", episodes: episodes)]
        }

        struct Bucket {
            var id: String
            var title: String
            var sortDate: Date
            var episodes: [InboxEpisodeProjection]
        }

        var buckets: [String: Bucket] = [:]
        for episode in episodes {
            let bucket = bucket(for: episode, grouping: grouping, calendar: calendar)
            buckets[bucket.id, default: Bucket(
                id: bucket.id,
                title: bucket.title,
                sortDate: bucket.sortDate,
                episodes: []
            )].episodes.append(episode)
        }

        return buckets
            .values
            .map { bucket in
                InboxEpisodeGroup(
                    id: bucket.id,
                    title: bucket.title,
                    episodes: bucket.episodes
                )
            }
            .sorted {
                if $0.episodes.first?.publishedAt != $1.episodes.first?.publishedAt {
                    return ($0.episodes.first?.publishedAt ?? .distantPast)
                        > ($1.episodes.first?.publishedAt ?? .distantPast)
                }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    private static func bucket(
        for episode: InboxEpisodeProjection,
        grouping: InboxGrouping,
        calendar: Calendar
    ) -> (id: String, title: String, sortDate: Date) {
        guard let date = episode.publishedAt else {
            return ("unknown", "Date unavailable", .distantPast)
        }

        switch grouping {
        case .none:
            return ("all", "All Episodes", date)
        case .podcast:
            return ("podcast:\(episode.podcastKey)", episode.podcastTitle, date)
        case .day:
            let start = calendar.startOfDay(for: date)
            return (
                "day:\(start.timeIntervalSinceReferenceDate)",
                start.formatted(date: .complete, time: .omitted),
                start
            )
        case .week:
            let interval = calendar.dateInterval(of: .weekOfYear, for: date)
                ?? DateInterval(start: date, duration: 7 * 24 * 60 * 60)
            let end = interval.end.addingTimeInterval(-1)
            return (
                "week:\(interval.start.timeIntervalSinceReferenceDate)",
                "\(interval.start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))",
                interval.start
            )
        }
    }
}

enum InboxCleanupPolicy: Equatable, Sendable {
    case never
    case olderThanDays(Int)
    case keepLatestPerPodcast(Int)

    var isEnabled: Bool {
        self != .never
    }

    var title: String {
        switch self {
        case .never: "Never"
        case let .olderThanDays(days): "Older than \(days) days"
        case let .keepLatestPerPodcast(count): "Keep latest \(count) per podcast"
        }
    }

    func eligibleIDs(
        from episodes: [InboxEpisodeProjection],
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Set<String> {
        let candidates = episodes.filter { $0.isProtectedFromCleanup == false }
        switch self {
        case .never:
            return []
        case let .olderThanDays(days):
            guard days > 0,
                  let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else {
                return []
            }
            return Set(candidates.compactMap { episode in
                guard let publishedAt = episode.publishedAt, publishedAt < cutoff else { return nil }
                return episode.id
            })
        case let .keepLatestPerPodcast(count):
            guard count >= 0 else { return [] }
            let byPodcast = Dictionary(grouping: candidates, by: \.podcastKey)
            return Set(byPodcast.values.flatMap { episodes in
                episodes
                    .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
                    .dropFirst(count)
                    .map(\.id)
            })
        }
    }
}

/// Captures only the fields changed by an undoable Inbox operation. The actor
/// restores a change only while the result still matches this snapshot, so a
/// later sync or local action is not blindly overwritten.
struct InboxTriageChange: Hashable, Sendable {
    let episodeURL: URL
    let previousInbox: Bool
    let previousSavedForLater: Bool
    let previousFavorite: Bool
    let resultInbox: Bool
    let resultSavedForLater: Bool
    let resultFavorite: Bool
}
