import Foundation
import SwiftData

enum PlaySessionSummaryPeriod: String, CaseIterable, Codable, Identifiable, Hashable {
    case day
    case week
    case month
    case year
    case forever

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Days"
        case .week: "Weeks"
        case .month: "Months"
        case .year: "Years"
        case .forever: "Forever"
        }
    }

    var singularTitle: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .forever: "Forever"
        }
    }
}

@Model
final class PlaySessionSummary: Identifiable {
    var id: UUID? = UUID()
    var periodKind: String? = PlaySessionSummaryPeriod.week.rawValue
    var periodStart: Date? = Date()
    var podcastFeed: URL?
    var podcastName: String?
    var totalSeconds: Double? = 0
    var silenceGapTimeSavedSeconds: Double? = 0
    var playbackRateTimeSavedSeconds: Double? = 0
    var activeHourCount: Int? = 0

    init(
        id: UUID? = UUID(),
        periodKind: String? = PlaySessionSummaryPeriod.week.rawValue,
        periodStart: Date? = Date(),
        podcastFeed: URL? = nil,
        podcastName: String? = nil,
        totalSeconds: Double? = 0,
        silenceGapTimeSavedSeconds: Double? = 0,
        playbackRateTimeSavedSeconds: Double? = 0,
        activeHourCount: Int? = 0
    ) {
        self.id = id
        self.periodKind = periodKind
        self.periodStart = periodStart
        self.podcastFeed = podcastFeed
        self.podcastName = podcastName
        self.totalSeconds = totalSeconds
        self.silenceGapTimeSavedSeconds = silenceGapTimeSavedSeconds
        self.playbackRateTimeSavedSeconds = playbackRateTimeSavedSeconds
        self.activeHourCount = activeHourCount
    }
}

extension PlaySessionSummary {
    /// The deterministic id `StoreSplitUserStateImporter` stamps on a summary row
    /// it writes back from `UserState.sqlite`.
    static func splitStoreProjectionID(
        feedURL: String,
        periodKind: String,
        periodStart: Date
    ) -> UUID {
        StableIdentityKey.uuid(for: StableIdentityKey.make(
            feedURL,
            periodKind,
            String(Int(periodStart.timeIntervalSince1970))
        ))
    }

    /// Whether this row is a read-back of the synced summaries rather than a
    /// rollup computed from local `PlaySession` rows.
    ///
    /// The two directions form a cycle otherwise: the importer deletes this whole
    /// table and rewrites it from `ListeningSummarySync`, and the migration reads
    /// the table back and republishes it as the authoritative `__legacy_shared__`
    /// record. Because the republish max-merges, one device's inflated total would
    /// become permanent for every device on the account and could never fall.
    var isSplitStoreProjection: Bool {
        guard let id, let periodKind, let periodStart else { return false }
        // The importer keys the id on whatever feed spelling the synced record
        // carried; the migration re-derives it from the stored URL. Accept either
        // so a normalization difference cannot re-open the cycle.
        let feedSpellings: Set<String> = podcastFeed.map {
            [$0.absoluteString, PodcastFeedIdentity.normalizedFeedURLString($0)]
        } ?? ["__all_podcasts__"]
        return feedSpellings.contains {
            Self.splitStoreProjectionID(
                feedURL: $0,
                periodKind: periodKind,
                periodStart: periodStart
            ) == id
        }
    }
}
