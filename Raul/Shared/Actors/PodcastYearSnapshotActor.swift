import Foundation
import SwiftData

@ModelActor
actor PodcastYearSnapshotActor {
    private struct Rollup {
        let key: String
        let feed: URL?
        let title: String
        let totalSeconds: Double
    }

    func request(
        year: Int,
        periodStart: Date,
        periodEnd: Date,
        significantListeningThreshold: TimeInterval,
        calendar: Calendar
    ) -> PodcastYearShareRequest? {
        let statRollups = listeningStatRollups(
            periodStart: periodStart,
            periodEnd: periodEnd
        )
        let rollups = statRollups.isEmpty
            ? summaryRollups(
                periodStart: periodStart,
                periodEnd: periodEnd,
                calendar: calendar
            )
            : statRollups

        guard rollups.isEmpty == false else { return nil }
        let totalSeconds = rollups.reduce(0) { $0 + $1.totalSeconds }
        guard totalSeconds > significantListeningThreshold else { return nil }

        let podcasts = (try? modelContext.fetch(FetchDescriptor<Podcast>())) ?? []
        let coverURLsByFeed = Dictionary(
            grouping: podcasts.compactMap { podcast -> (String, URL?)? in
                guard let feed = podcast.feed?.absoluteString else { return nil }
                return (feed, podcast.imageURL)
            },
            by: \.0
        )
        .mapValues { $0.first?.1 ?? nil }
        let coverURLsByTitle = Dictionary(grouping: podcasts, by: \.title)
            .mapValues { $0.first?.imageURL }

        let requestPodcasts = rollups
            .sorted { $0.totalSeconds > $1.totalSeconds }
            .enumerated()
            .map { index, rollup in
                let feedString = rollup.feed?.absoluteString
                return PodcastYearPodcast(
                    rank: index + 1,
                    title: rollup.title,
                    totalSeconds: rollup.totalSeconds,
                    coverURL: feedString.flatMap { coverURLsByFeed[$0] }
                        ?? coverURLsByTitle[rollup.title]
                        ?? nil
                )
            }

        return PodcastYearShareRequest(
            year: year,
            periodStart: periodStart,
            periodEnd: periodEnd,
            podcasts: requestPodcasts
        )
    }

    private func listeningStatRollups(
        periodStart: Date,
        periodEnd: Date
    ) -> [Rollup] {
        let predicate = #Predicate<ListeningStat> { stat in
            stat.startOfHour != nil
                && stat.startOfHour! >= periodStart
                && stat.startOfHour! < periodEnd
        }
        let stats = ((try? modelContext.fetch(
            FetchDescriptor<ListeningStat>(predicate: predicate)
        )) ?? []).filter { ($0.totalSeconds ?? 0) > 0 }

        return groupedRollups(stats.compactMap { stat in
            let totalSeconds = stat.totalSeconds ?? 0
            guard totalSeconds > 0 else { return nil }
            let title = stat.podcastName ?? "Podcast"
            return Rollup(
                key: stat.podcastFeed?.absoluteString ?? title,
                feed: stat.podcastFeed,
                title: title,
                totalSeconds: totalSeconds
            )
        })
    }

    private func summaryRollups(
        periodStart: Date,
        periodEnd: Date,
        calendar: Calendar
    ) -> [Rollup] {
        for period in [
            PlaySessionSummaryPeriod.year,
            .month,
            .week,
            .day
        ] {
            let periodKind = period.rawValue
            let descriptor = FetchDescriptor<PlaySessionSummary>(
                predicate: #Predicate<PlaySessionSummary> { summary in
                    summary.periodKind == periodKind
                        && summary.periodStart != nil
                        && summary.periodStart! >= periodStart
                        && summary.periodStart! < periodEnd
                },
                sortBy: [SortDescriptor(\.periodStart, order: .reverse)]
            )
            let primary = (try? modelContext.fetch(descriptor)) ?? []
            let candidates: [PlaySessionSummary]
            if primary.isEmpty {
                let fallback = (try? modelContext.fetch(
                    FetchDescriptor<PlaySessionSummary>(
                        sortBy: [SortDescriptor(\.periodStart, order: .reverse)]
                    )
                )) ?? []
                candidates = fallback.filter {
                    $0.periodKind == periodKind
                        && ($0.periodStart ?? .distantPast) >= periodStart
                        && ($0.periodStart ?? .distantFuture) < periodEnd
                }
            } else {
                candidates = primary
            }

            let summaries = candidates.filter { summary in
                guard let summaryStart = summary.periodStart,
                      (summary.totalSeconds ?? 0) > 0 else {
                    return false
                }
                return period != .year
                    || calendar.isDate(summaryStart, equalTo: periodStart, toGranularity: .day)
            }
            let rollups = groupedRollups(summaries.compactMap { summary in
                let totalSeconds = summary.totalSeconds ?? 0
                guard totalSeconds > 0 else { return nil }
                let title = summary.podcastName ?? "Podcast"
                return Rollup(
                    key: summary.podcastFeed?.absoluteString ?? title,
                    feed: summary.podcastFeed,
                    title: title,
                    totalSeconds: totalSeconds
                )
            })
            if rollups.isEmpty == false {
                return rollups
            }
        }
        return []
    }

    private func groupedRollups(_ rollups: [Rollup]) -> [Rollup] {
        Dictionary(grouping: rollups, by: \.key).map { _, values in
            let first = values[0]
            return Rollup(
                key: first.key,
                feed: first.feed,
                title: first.title,
                totalSeconds: values.reduce(0) { $0 + $1.totalSeconds }
            )
        }
    }
}
