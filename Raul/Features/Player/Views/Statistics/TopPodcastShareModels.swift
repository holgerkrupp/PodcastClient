import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct PodcastRollup: Identifiable {
    let podcastName: String
    let podcastFeed: URL?
    let coverURL: URL?
    let totalSeconds: Double

    var id: String { podcastFeed?.absoluteString ?? podcastName }
}

struct TopPodcastShareItem: Identifiable {
    let rank: Int
    let podcastName: String
    let totalSeconds: Double
    let coverImage: UIImage?

    var id: Int { rank }
}

struct TopPodcastShareTimelineRollup: Identifiable {
    let date: Date
    let podcastName: String
    let podcastFeed: URL?
    let coverURL: URL?
    let totalSeconds: Double
    let coveragePeriod: PlaySessionSummaryPeriod?

    init(
        date: Date,
        podcastName: String,
        podcastFeed: URL?,
        coverURL: URL?,
        totalSeconds: Double,
        coveragePeriod: PlaySessionSummaryPeriod? = nil
    ) {
        self.date = date
        self.podcastName = podcastName
        self.podcastFeed = podcastFeed
        self.coverURL = coverURL
        self.totalSeconds = totalSeconds
        self.coveragePeriod = coveragePeriod
    }

    var id: String {
        "\(date.timeIntervalSinceReferenceDate)-\(podcastFeed?.absoluteString ?? podcastName)"
    }
}

struct TopPodcastShareTimelineEntry: Identifiable {
    let date: Date
    let podcastName: String
    let totalSeconds: Double
    let coverImage: UIImage?
    let coveragePeriod: PlaySessionSummaryPeriod?

    init(
        date: Date,
        podcastName: String,
        totalSeconds: Double,
        coverImage: UIImage?,
        coveragePeriod: PlaySessionSummaryPeriod? = nil
    ) {
        self.date = date
        self.podcastName = podcastName
        self.totalSeconds = totalSeconds
        self.coverImage = coverImage
        self.coveragePeriod = coveragePeriod
    }

    var id: String {
        "\(date.timeIntervalSinceReferenceDate)-\(podcastName)"
    }
}

struct TopPodcastShareStats {
    let title: String
    let dateRangeLabel: String
    let topPodcastName: String
    let topPodcastListeningTime: String
    let totalListeningTime: String
    let podcastCount: Int
    let listeningSessionCount: Int
    let busiestDayLabel: String
    let busiestHourLabel: String

    var renderSignature: String {
        [
            title,
            dateRangeLabel,
            topPodcastName,
            topPodcastListeningTime,
            totalListeningTime,
            "\(podcastCount)",
            "\(listeningSessionCount)",
            busiestDayLabel,
            busiestHourLabel
        ].joined(separator: "|")
    }
}

enum TopPodcastShareAspect {
    static let defaultVideoSize = CGSize(width: 720, height: 1280)

    static func renderSize(for videoSize: CGSize) -> CGSize {
        if abs(videoSize.width - videoSize.height) < 1 {
            return CGSize(width: 1080, height: 1080)
        }
        if videoSize.width > videoSize.height {
            return CGSize(width: 1920, height: 1080)
        }
        return CGSize(width: 1080, height: 1920)
    }

    static func aspectRatio(for videoSize: CGSize) -> CGFloat {
        let size = renderSize(for: videoSize)
        return size.width / max(size.height, 1)
    }
}

enum TopPodcastShareBackground: String, CaseIterable, Identifiable {
    case current
    case stripes
    case rainbowGradient
    case white
    case black
    case january
    case february
    case march
    case april
    case may
    case june
    case july
    case august
    case september
    case october
    case november
    case december
    case newYear
    case carnival
    case christmas
    case easter
    case ramadan
    case eidAlFitr
    case hanukkah
    case holi
    case diwali
    case lunarNewYear
    case midsummer
    case halloween

    var id: Self { self }

    var title: String {
        switch self {
        case .current:
            return "Boring"
        case .stripes:
            return "Rainbow"
        case .rainbowGradient:
            return "45 Gradient"
        case .white:
            return "White"
        case .black:
            return "Black"
        case .january:
            return "January"
        case .february:
            return "February"
        case .march:
            return "March"
        case .april:
            return "April"
        case .may:
            return "May"
        case .june:
            return "June"
        case .july:
            return "July"
        case .august:
            return "August"
        case .september:
            return "September"
        case .october:
            return "October"
        case .november:
            return "November"
        case .december:
            return "December"
        case .newYear:
            return "New Year"
        case .carnival:
            return "Carnival"
        case .christmas:
            return "Christmas"
        case .easter:
            return "Easter"
        case .ramadan:
            return "Ramadan"
        case .eidAlFitr:
            return "Eid al-Fitr"
        case .hanukkah:
            return "Hanukkah"
        case .holi:
            return "Holi"
        case .diwali:
            return "Diwali"
        case .lunarNewYear:
            return "Lunar New Year"
        case .midsummer:
            return "Midsummer"
        case .halloween:
            return "Halloween"
        }
    }

    var isLight: Bool {
        self == .white
    }

    var seasonalMonth: Int? {
        switch self {
        case .january:
            return 1
        case .february:
            return 2
        case .march:
            return 3
        case .april:
            return 4
        case .may:
            return 5
        case .june:
            return 6
        case .july:
            return 7
        case .august:
            return 8
        case .september:
            return 9
        case .october:
            return 10
        case .november:
            return 11
        case .december:
            return 12
        default:
            return nil
        }
    }

    var occasionConfig: SeasonalBackgroundConfig? {
        switch self {
        case .newYear:
            return SeasonalBackgroundConfig.occasion(
                kind: .fireworks,
                baseColors: [Color(red: 0.02, green: 0.04, blue: 0.12), Color(red: 0.08, green: 0.12, blue: 0.28), Color(red: 0.34, green: 0.20, blue: 0.44)],
                accentColors: [Color(red: 1.00, green: 0.84, blue: 0.30), Color(red: 0.44, green: 0.78, blue: 1.00), Color(red: 0.98, green: 0.32, blue: 0.52), Color(red: 0.76, green: 0.58, blue: 1.00)]
            )
        case .carnival:
            return SeasonalBackgroundConfig.occasion(
                kind: .confetti,
                baseColors: [Color(red: 0.12, green: 0.06, blue: 0.22), Color(red: 0.30, green: 0.12, blue: 0.38), Color(red: 0.90, green: 0.34, blue: 0.34)],
                accentColors: [Color(red: 1.00, green: 0.80, blue: 0.20), Color(red: 0.10, green: 0.72, blue: 0.82), Color(red: 0.96, green: 0.22, blue: 0.58), Color(red: 0.34, green: 0.74, blue: 0.34)]
            )
        case .christmas:
            return SeasonalBackgroundConfig.occasion(
                kind: .christmasTrees,
                baseColors: [Color(red: 0.02, green: 0.08, blue: 0.07), Color(red: 0.06, green: 0.20, blue: 0.14), Color(red: 0.38, green: 0.06, blue: 0.08)],
                accentColors: [Color(red: 0.95, green: 0.78, blue: 0.34), Color(red: 0.86, green: 0.12, blue: 0.12), Color(red: 0.18, green: 0.56, blue: 0.30), Color(red: 0.88, green: 0.96, blue: 1.00)]
            )
        case .easter:
            return SeasonalBackgroundConfig.occasion(
                kind: .easter,
                baseColors: [Color(red: 0.12, green: 0.22, blue: 0.20), Color(red: 0.30, green: 0.42, blue: 0.34), Color(red: 0.72, green: 0.54, blue: 0.76)],
                accentColors: [Color(red: 0.98, green: 0.78, blue: 0.88), Color(red: 0.78, green: 0.86, blue: 1.00), Color(red: 0.98, green: 0.88, blue: 0.50), Color(red: 0.70, green: 0.92, blue: 0.60)]
            )
        case .ramadan:
            return SeasonalBackgroundConfig.occasion(
                kind: .crescent,
                baseColors: [Color(red: 0.01, green: 0.05, blue: 0.14), Color(red: 0.03, green: 0.14, blue: 0.24), Color(red: 0.07, green: 0.26, blue: 0.28)],
                accentColors: [Color(red: 0.90, green: 0.78, blue: 0.48), Color(red: 0.16, green: 0.58, blue: 0.54), Color(red: 0.62, green: 0.82, blue: 0.88)]
            )
        case .eidAlFitr:
            return SeasonalBackgroundConfig.occasion(
                kind: .lanterns,
                baseColors: [Color(red: 0.04, green: 0.10, blue: 0.16), Color(red: 0.08, green: 0.24, blue: 0.24), Color(red: 0.36, green: 0.22, blue: 0.42)],
                accentColors: [Color(red: 0.98, green: 0.80, blue: 0.36), Color(red: 0.46, green: 0.82, blue: 0.70), Color(red: 0.90, green: 0.48, blue: 0.74)]
            )
        case .hanukkah:
            return SeasonalBackgroundConfig.occasion(
                kind: .candles,
                baseColors: [Color(red: 0.02, green: 0.06, blue: 0.16), Color(red: 0.06, green: 0.18, blue: 0.36), Color(red: 0.40, green: 0.52, blue: 0.70)],
                accentColors: [Color(red: 0.82, green: 0.92, blue: 1.00), Color(red: 0.18, green: 0.48, blue: 0.92), Color(red: 1.00, green: 0.78, blue: 0.36)]
            )
        case .holi:
            return SeasonalBackgroundConfig.occasion(
                kind: .colorClouds,
                baseColors: [Color(red: 0.08, green: 0.10, blue: 0.18), Color(red: 0.22, green: 0.16, blue: 0.34), Color(red: 0.46, green: 0.24, blue: 0.44)],
                accentColors: [Color(red: 1.00, green: 0.20, blue: 0.48), Color(red: 0.22, green: 0.72, blue: 1.00), Color(red: 1.00, green: 0.82, blue: 0.12), Color(red: 0.28, green: 0.84, blue: 0.44)]
            )
        case .diwali:
            return SeasonalBackgroundConfig.occasion(
                kind: .diyas,
                baseColors: [Color(red: 0.10, green: 0.03, blue: 0.04), Color(red: 0.34, green: 0.08, blue: 0.04), Color(red: 0.78, green: 0.28, blue: 0.06)],
                accentColors: [Color(red: 1.00, green: 0.78, blue: 0.20), Color(red: 1.00, green: 0.44, blue: 0.08), Color(red: 0.92, green: 0.24, blue: 0.72)]
            )
        case .lunarNewYear:
            return SeasonalBackgroundConfig.occasion(
                kind: .lanterns,
                baseColors: [Color(red: 0.12, green: 0.02, blue: 0.06), Color(red: 0.34, green: 0.05, blue: 0.08), Color(red: 0.70, green: 0.22, blue: 0.08)],
                accentColors: [Color(red: 1.00, green: 0.78, blue: 0.24), Color(red: 0.86, green: 0.12, blue: 0.10), Color(red: 1.00, green: 0.44, blue: 0.24)]
            )
        case .midsummer:
            return SeasonalBackgroundConfig.occasion(
                kind: .midsummer,
                baseColors: [Color(red: 0.04, green: 0.20, blue: 0.24), Color(red: 0.16, green: 0.38, blue: 0.30), Color(red: 0.88, green: 0.62, blue: 0.30)],
                accentColors: [Color(red: 1.00, green: 0.84, blue: 0.30), Color(red: 0.52, green: 0.82, blue: 0.38), Color(red: 0.96, green: 0.56, blue: 0.72)]
            )
        case .halloween:
            return SeasonalBackgroundConfig.occasion(
                kind: .halloween,
                baseColors: [Color(red: 0.04, green: 0.04, blue: 0.08), Color(red: 0.16, green: 0.08, blue: 0.18), Color(red: 0.70, green: 0.28, blue: 0.06)],
                accentColors: [Color(red: 1.00, green: 0.48, blue: 0.08), Color(red: 0.44, green: 0.24, blue: 0.62), Color(red: 0.12, green: 0.12, blue: 0.16)]
            )
        default:
            return nil
        }
    }

    static let stripeColors: [Color] = [
        Color(.displayP3, red: 0.4685, green: 0.7231, blue: 0.3381, opacity: 1),
        Color(.displayP3, red: 0.9526, green: 0.7310, blue: 0.2930, opacity: 1),
        Color(.displayP3, red: 0.9033, green: 0.5332, blue: 0.2329, opacity: 1),
        Color(.displayP3, red: 0.8135, green: 0.2847, blue: 0.2712, opacity: 1),
        Color(.displayP3, red: 0.5425, green: 0.2603, blue: 0.5791, opacity: 1),
        Color(.displayP3, red: 0.2730, green: 0.6084, blue: 0.8413, opacity: 1)
    ]
}

enum TopPodcastShareDesign: CaseIterable, Identifiable {
    case podium
    case billboard
    case coverGrid
    case coverCollage
    case coverCloud
    case horizontalBars
    case pieChart
    case statistics
    case calendar
    case yearCalendar

    var id: Self { self }

    var title: String {
        switch self {
        case .podium:
            return "Podium Top 3"
        case .billboard:
            return "Billboard Top 10"
        case .coverGrid:
            return "Cover Grid"
        case .coverCollage:
            return "Cover Collage"
        case .coverCloud:
            return "Cover Cloud"
        case .horizontalBars:
            return "Playtime Bars"
        case .pieChart:
            return "Playtime Pie"
        case .statistics:
            return "Stats Wrapped"
        case .calendar:
            return "Calendar"
        case .yearCalendar:
            return "Year Calendar"
        }
    }

    var systemImage: String {
        switch self {
        case .podium:
            return "trophy"
        case .billboard:
            return "list.number"
        case .coverGrid:
            return "square.grid.3x3"
        case .coverCollage:
            return "rectangle.3.group"
        case .coverCloud:
            return "square.stack.3d.up"
        case .horizontalBars:
            return "chart.bar.xaxis"
        case .pieChart:
            return "chart.pie"
        case .statistics:
            return "sparkles"
        case .calendar:
            return "calendar"
        case .yearCalendar:
            return "calendar.badge.clock"
        }
    }

    var minimumItemCount: Int {
        switch self {
        case .podium:
            return 3
        case .billboard:
            return 1
        case .coverGrid:
            return 9
        case .coverCollage:
            return 5
        case .coverCloud:
            return 1
        case .horizontalBars:
            return 1
        case .pieChart:
            return 1
        case .statistics:
            return 1
        case .calendar:
            return 1
        case .yearCalendar:
            return 1
        }
    }

    var usesAllItems: Bool {
        self == .coverCloud
    }

    var itemLimit: Int {
        switch self {
        case .podium:
            return 3
        case .billboard:
            return 10
        case .coverGrid:
            return 12
        case .coverCollage:
            return 13
        case .coverCloud:
            return Int.max
        case .horizontalBars, .pieChart:
            return 10
        case .statistics, .calendar, .yearCalendar:
            return 1
        }
    }

    func supports(period: PlaySessionSummaryPeriod) -> Bool {
        switch self {
        case .calendar:
            return period != .forever
        case .yearCalendar:
            return period == .year
        default:
            return true
        }
    }
}
