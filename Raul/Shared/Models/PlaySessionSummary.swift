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
