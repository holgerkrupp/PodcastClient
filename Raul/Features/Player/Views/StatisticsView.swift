import SwiftUI
import SwiftData
import Charts
import UIKit

private struct ListeningOverviewPoint: Identifiable {
    let date: Date
    let totalSeconds: Double

    var id: Date { date }
}

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

    fileprivate var occasionConfig: SeasonalBackgroundConfig? {
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
        case .statistics:
            return 1
        }
    }
}

private struct PeriodListeningTotal: Identifiable {
    let start: Date
    let totalSeconds: Double

    var id: Date { start }
}

private struct WeekdayListeningTotal: Identifiable {
    let weekday: Int
    let label: String
    let totalSeconds: Double

    var id: Int { weekday }
}

private struct RecentListeningSession: Identifiable {
    let id: String
    let episodeTitle: String
    let podcastName: String
    let listenedSeconds: Double
    let startTime: Date
    let endedCleanly: Bool
    let startPosition: Double?
    let endPosition: Double?
}

private struct ListeningHeatMapSnapshot {
    static let empty = ListeningHeatMapSnapshot(secondsByWeekday: [:], maxSeconds: 1)

    let secondsByWeekday: [Int: [Double]]
    let maxSeconds: Double

    var hasData: Bool {
        secondsByWeekday.values.contains { hours in
            hours.contains(where: { $0 > 0 })
        }
    }

    func seconds(weekday: Int, hour: Int) -> Double {
        guard let hours = secondsByWeekday[weekday], hours.indices.contains(hour) else { return 0 }
        return hours[hour]
    }
}

private struct ListeningHistorySnapshot {
    static let empty = ListeningHistorySnapshot(
        selectedPodcastTitle: "All Podcasts",
        groupedTotals: [],
        chartPoints: [],
        selectedPeriodTotalSeconds: 0,
        totalListeningSeconds: 0,
        averagePeriodSeconds: 0,
        bestPeriod: nil,
        podcastBreakdown: [],
        selectedPeriodSessions: [],
        weekdayTotals: [],
        heatMap: .empty,
        isUsingSummaryTotals: false
    )

    let selectedPodcastTitle: String
    let groupedTotals: [PeriodListeningTotal]
    let chartPoints: [ListeningOverviewPoint]
    let selectedPeriodTotalSeconds: Double
    let totalListeningSeconds: Double
    let averagePeriodSeconds: Double
    let bestPeriod: PeriodListeningTotal?
    let podcastBreakdown: [PodcastRollup]
    let selectedPeriodSessions: [RecentListeningSession]
    let weekdayTotals: [WeekdayListeningTotal]
    let heatMap: ListeningHeatMapSnapshot
    let isUsingSummaryTotals: Bool
}

struct StatisticsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Podcast.title) private var podcasts: [Podcast]

    @State private var selectedPeriod: PlaySessionSummaryPeriod = .day
    @State private var selectedPeriodStart = Calendar.current.startOfDay(for: Date())
    @State private var selectedPodcastFeedString: String? = nil
    @State private var snapshot = ListeningHistorySnapshot.empty
    @State private var isPreparingPodcastShare = false
    @State private var showPodcastShareSheet = false
    @State private var podcastShareImage: UIImage?
    @State private var showInitialShareGallery = false
    @State private var didPresentInitialShareGallery = false

    private let presentShareGalleryOnAppear: Bool

    init(
        initialPeriod: PlaySessionSummaryPeriod = .day,
        initialPeriodStart: Date? = nil,
        presentShareGalleryOnAppear: Bool = false
    ) {
        self.presentShareGalleryOnAppear = presentShareGalleryOnAppear
        _selectedPeriod = State(initialValue: initialPeriod)
        _selectedPeriodStart = State(initialValue: initialPeriodStart ?? Calendar.current.startOfDay(for: Date()))
    }

    private let summaryGrid = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var weekdayLabels: [String] {
        let symbols = Calendar.current.shortWeekdaySymbols
        let firstWeekday = Calendar.current.firstWeekday - 1
        return (0..<7).map { offset in
            symbols[(firstWeekday + offset) % 7]
        }
    }

    private var weekdayOrder: [Int] {
        let firstWeekday = Calendar.current.firstWeekday - 1
        return (0..<7).map { (firstWeekday + $0) % 7 }
    }

    private var selectedPeriodSingular: String {
        String(selectedPeriod.title.dropLast())
    }

    private var selectedPeriodLabel: String {
        periodLabel(for: selectedPeriodStart, period: selectedPeriod)
    }

    private var selectedShareDateRangeLabel: String {
        periodDateRangeLabel(for: selectedPeriodStart, period: selectedPeriod)
    }

    private var selectedSharePeriodLabel: String {
        sharePeriodLabel(for: selectedPeriodStart, period: selectedPeriod)
    }

    private var selectedShareStats: TopPodcastShareStats {
        let topPodcast = snapshot.podcastBreakdown.first
        let totalListeningSeconds = snapshot.podcastBreakdown.reduce(0) { $0 + $1.totalSeconds }
        let busiestDay = snapshot.weekdayTotals.max { $0.totalSeconds < $1.totalSeconds }

        return TopPodcastShareStats(
            title: "Your Up Next \(selectedSharePeriodLabel)",
            dateRangeLabel: selectedShareDateRangeLabel,
            topPodcastName: topPodcast?.podcastName ?? "No podcast yet",
            topPodcastListeningTime: topPodcast.map { formatDuration($0.totalSeconds) } ?? "0m",
            totalListeningTime: formatDuration(totalListeningSeconds),
            podcastCount: snapshot.podcastBreakdown.count,
            listeningSessionCount: snapshot.selectedPeriodSessions.count,
            busiestDayLabel: busiestDay.map { $0.totalSeconds > 0 ? $0.label : "No data yet" } ?? "No data yet",
            busiestHourLabel: busiestHourLabel(for: snapshot.heatMap)
        )
    }

    private var canMoveToNextPeriod: Bool {
        selectedPeriodStart < periodStart(for: Date(), period: selectedPeriod)
    }

    private var refreshSignature: String {
        let podcastSignature = podcasts.prefix(3).map(\.title).joined(separator: "|")
        return "\(selectedPeriod.rawValue)|\(selectedPeriodStart.timeIntervalSinceReferenceDate)|\(selectedPodcastFeedString ?? "all")|\(podcasts.count)|\(podcastSignature)"
    }

    var body: some View {
        List {
            Section {
                Picker("Period", selection: $selectedPeriod) {
                    ForEach(PlaySessionSummaryPeriod.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Podcast", selection: $selectedPodcastFeedString) {
                    Text("All Podcasts").tag(String?.none)
                    ForEach(podcasts, id: \.id) { podcast in
                        Text(podcast.title).tag(Optional(podcast.feed?.absoluteString ?? ""))
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 12) {
                    Button {
                        moveSelectedPeriod(by: -1)
                    } label: {
                        Label("", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(Text("Move to previous \(selectedPeriodSingular)"))

                    Spacer(minLength: 8)

                    VStack(spacing: 2) {
                        Text(selectedPeriodLabel)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(snapshot.selectedPodcastTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Button {
                        moveSelectedPeriod(by: 1)
                    } label: {
                        Label("", systemImage: "chevron.right")
                    }
                    .accessibilityLabel(Text("Move to next \(selectedPeriodSingular)"))
                    .buttonStyle(.bordered)
                    .disabled(!canMoveToNextPeriod)
                }

            }

            Section{
                NavigationLink {
                    TopPodcastShareGalleryView(
                        rollups: snapshot.podcastBreakdown,
                        periodLabel: selectedSharePeriodLabel,
                        dateRangeLabel: selectedShareDateRangeLabel,
                        stats: selectedShareStats
                    )
                } label: {
                    Label("Share Top Podcasts", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(snapshot.podcastBreakdown.isEmpty)
            }
            
            Section {

                
                LazyVGrid(columns: summaryGrid, spacing: 12) {
                    summaryCard(
                        title: "Total Listening",
                        value: formatDuration(snapshot.totalListeningSeconds),
                        detail: "\(snapshot.groupedTotals.count) \(selectedPeriod.title.lowercased()) tracked"
                    )
                    summaryCard(
                        title: "Average \(selectedPeriodSingular)",
                        value: formatDuration(snapshot.averagePeriodSeconds),
                        detail: snapshot.selectedPodcastTitle
                    )
                    summaryCard(
                        title: "Best \(selectedPeriodSingular)",
                        value: snapshot.bestPeriod.map { formatDuration($0.totalSeconds) } ?? "None",
                        detail: snapshot.bestPeriod.map { periodLabel(for: $0.start, period: selectedPeriod) } ?? "No data yet"
                    )
                    summaryCard(
                        title: selectedPeriodLabel,
                        value: formatDuration(snapshot.selectedPeriodTotalSeconds),
                        detail: "\(selectedPeriodSingular) total"
                    )
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            if !snapshot.chartPoints.isEmpty {
                Section("Listening Trend") {
                    Text("Y-axis: listening time per \(selectedPeriodSingular.lowercased()).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Chart(snapshot.chartPoints) { point in
                        AreaMark(
                            x: .value("Period", point.date),
                            y: .value("Listening", point.totalSeconds)
                        )
                        .foregroundStyle(.accent.opacity(0.28))
                        .interpolationMethod(.catmullRom)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let seconds = value.as(Double.self) {
                                    Text(shortDuration(seconds))
                                }
                            }
                        }
                    }
                    .frame(height: 220)
                }
            }

            if snapshot.heatMap.hasData {
                Section("Listening Habits") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("When you usually listen")
                            .font(.headline)
                        Text("Weekday totals and an hour-by-weekday heat map based on your listening history.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Chart(snapshot.weekdayTotals) { item in
                            BarMark(
                                x: .value("Weekday", item.label),
                                y: .value("Listening", item.totalSeconds)
                            )
                            .foregroundStyle(.accent)
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading) { value in
                                AxisGridLine()
                                AxisTick()
                                AxisValueLabel {
                                    if let seconds = value.as(Double.self) {
                                        Text(shortDuration(seconds))
                                    }
                                }
                            }
                        }
                        .frame(height: 180)

                        listeningHeatMap
                    }
                    .padding(.vertical, 6)
                }
            }

            if selectedPodcastFeedString == nil && !snapshot.podcastBreakdown.isEmpty {
                Section {
                    NavigationLink {
                        TopPodcastShareGalleryView(
                            rollups: snapshot.podcastBreakdown,
                            periodLabel: selectedSharePeriodLabel,
                            dateRangeLabel: selectedShareDateRangeLabel,
                            stats: selectedShareStats
                        )
                    } label: {
                        Label("Share Top Podcasts", systemImage: "photo.on.rectangle.angled")
                    }
                    .disabled(snapshot.podcastBreakdown.isEmpty)
                    
                    let maxPodcastSeconds = snapshot.podcastBreakdown.first?.totalSeconds ?? 0
                    ForEach(snapshot.podcastBreakdown.prefix(8)) { rollup in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rollup.podcastName)
                                    .font(.headline)
                                Text(formatDuration(rollup.totalSeconds))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            ProgressView(
                                value: rollup.totalSeconds,
                                total: maxPodcastSeconds == 0 ? rollup.totalSeconds : maxPodcastSeconds
                            )
                            .frame(width: 100)
                        }
                    }
                } header: {
                    HStack {
                        Text("Top Podcasts")
                        
                    }
                }
            }
            

            Section("\(selectedPeriodSingular) Sessions") {
                if snapshot.groupedTotals.isEmpty {
                    ContentUnavailableView(
                        "No Listening History",
                        systemImage: "chart.bar.xaxis",
                        description: Text("Start listening to see your summarized playback history here.")
                    )
                } else if snapshot.selectedPeriodSessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "calendar.badge.minus",
                        description: Text("No listening sessions in this \(selectedPeriodSingular.lowercased()).")
                    )
                } else {
                    ForEach(snapshot.selectedPeriodSessions.prefix(15)) { session in
                        RecentListeningSessionRow(session: session)
                    }

                    if snapshot.selectedPeriodSessions.count > 15 {
                        NavigationLink {
                            ListeningSessionsListView(
                                sessions: snapshot.selectedPeriodSessions,
                                title: "\(selectedPeriodSingular) Sessions",
                                subtitle: selectedShareDateRangeLabel
                            )
                        } label: {
                            Label(
                                "Show All Play Sessions",
                                systemImage: "list.bullet.rectangle"
                            )
                            .badge(snapshot.selectedPeriodSessions.count)
                        }
                    }
                }
            }

            if !snapshot.groupedTotals.isEmpty {
                Section("Recent \(selectedPeriod.title)") {
                    ForEach(snapshot.groupedTotals.prefix(24)) { item in
                        Button {
                            selectedPeriodStart = periodStart(for: item.start, period: selectedPeriod)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(periodLabel(for: item.start, period: selectedPeriod))
                                        .font(.headline)
                                    Text(snapshot.selectedPodcastTitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(formatDuration(item.totalSeconds))
                                    .font(.headline)
                                    .monospacedDigit()

                                if isSamePeriodStart(item.start, as: selectedPeriodStart, period: selectedPeriod) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.accent)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

       
        }
        .navigationTitle("Listening History")
        .listStyle(.insetGrouped)
        .task(id: refreshSignature) {
            refreshSnapshot()
            presentInitialShareGalleryIfNeeded()
        }
        .sheet(isPresented: $showPodcastShareSheet) {
            if let podcastShareImage {
                ShareSheet(activityItems: [podcastShareImage])
            }
        }
        .sheet(isPresented: $showInitialShareGallery) {
            NavigationStack {
                TopPodcastShareGalleryView(
                    rollups: snapshot.podcastBreakdown,
                    periodLabel: selectedSharePeriodLabel,
                    dateRangeLabel: selectedShareDateRangeLabel,
                    stats: selectedShareStats
                )
            }
        }
        .onChange(of: selectedPeriod) { _, newValue in
            selectedPeriodStart = periodStart(for: Date(), period: newValue)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let horizontal = value.translation.width
                    let vertical = value.translation.height
                    guard abs(horizontal) > abs(vertical) * 1.25, abs(horizontal) > 50 else { return }

                    if horizontal < 0 {
                        if canMoveToNextPeriod {
                            moveSelectedPeriod(by: 1)
                        }
                    } else {
                        moveSelectedPeriod(by: -1)
                    }
                }
        )
    }

    private func refreshSnapshot() {
        let selectedPeriodEnd = nextPeriodStart(from: selectedPeriodStart, period: selectedPeriod)
        let lookbackPeriods = overviewPeriodCount(for: selectedPeriod)
        let overviewStart = periodStartByAdding(-lookbackPeriods, to: selectedPeriodStart, period: selectedPeriod)
        let selectedPodcastURL = selectedPodcastFeedString.flatMap(URL.init(string:))
        let selectedPodcastTitle: String
        if let selectedPodcastFeedString {
            selectedPodcastTitle = podcasts.first(where: { $0.feed?.absoluteString == selectedPodcastFeedString })?.title ?? "Selected Podcast"
        } else {
            selectedPodcastTitle = "All Podcasts"
        }

        let fetchedSummaries = fetchSummariesInWindow(
            period: selectedPeriod,
            overviewStart: overviewStart,
            selectedPeriodEnd: selectedPeriodEnd,
            selectedPodcastFeedString: selectedPodcastFeedString,
            selectedPodcastURL: selectedPodcastURL,
            lookbackPeriods: lookbackPeriods
        )

        let sessionsInWindow = fetchSessionsInWindow(
            overviewStart: overviewStart,
            selectedPeriodEnd: selectedPeriodEnd,
            selectedPodcastFeedString: selectedPodcastFeedString
        )

        let summaryTotals = Dictionary(grouping: fetchedSummaries.compactMap { summary -> (Date, Double)? in
            guard let periodStart = summary.periodStart else { return nil }
            return (periodStart, summary.totalSeconds ?? 0)
        }, by: \.0)
        .map { key, values in
            PeriodListeningTotal(start: key, totalSeconds: values.reduce(0) { $0 + $1.1 })
        }
        .sorted { $0.start > $1.start }

        let rawSessionTotals = Dictionary(grouping: sessionsInWindow.compactMap { session -> (Date, Double)? in
            guard let startTime = session.startTime else { return nil }
            let listened = listenedSeconds(for: session)
            guard listened > 0 else { return nil }
            return (periodStart(for: startTime, period: selectedPeriod), listened)
        }, by: \.0)
        .map { key, values in
            PeriodListeningTotal(start: key, totalSeconds: values.reduce(0) { $0 + $1.1 })
        }
        .sorted { $0.start > $1.start }

        let groupedTotals = summaryTotals.isEmpty ? rawSessionTotals : summaryTotals
        let totalListeningSeconds = groupedTotals.reduce(0) { $0 + $1.totalSeconds }
        let averagePeriodSeconds = groupedTotals.isEmpty ? 0 : (totalListeningSeconds / Double(groupedTotals.count))
        let chartPoints = Array(
            groupedTotals
                .prefix(12)
                .map { ListeningOverviewPoint(date: $0.start, totalSeconds: $0.totalSeconds) }
                .reversed()
        )

        let selectedPeriodRawSessions = sessionsInWindow
            .filter { session in
                guard let startTime = session.startTime else { return false }
                return startTime >= selectedPeriodStart && startTime < selectedPeriodEnd
            }

        let selectedPeriodSessions = selectedPeriodRawSessions
            .map { session in
                RecentListeningSession(
                    id: session.id?.uuidString ?? "\(session.startTime?.timeIntervalSinceReferenceDate ?? 0)-\(session.podcastName ?? "unknown")",
                    episodeTitle: session.episode?.title ?? "Unknown Episode",
                    podcastName: session.podcastName ?? "Unknown Podcast",
                    listenedSeconds: listenedSeconds(for: session),
                    startTime: session.startTime ?? Date(),
                    endedCleanly: session.endedCleanly ?? false,
                    startPosition: session.startPosition,
                    endPosition: session.endPosition
                )
            }

        let podcastBreakdown: [PodcastRollup]
        if selectedPodcastFeedString == nil {
            let podcastCoversByFeed = Dictionary(
                grouping: podcasts.compactMap { podcast -> (String, URL?)? in
                    guard let feed = podcast.feed?.absoluteString else { return nil }
                    return (feed, podcast.imageURL)
                },
                by: \.0
            )
            .mapValues { $0.first?.1 }

            let podcastCoversByTitle = Dictionary(grouping: podcasts, by: \.title)
                .mapValues { $0.first?.imageURL }

            let selectedPeriodSummaries = fetchedSummaries.filter { summary in
                guard let periodStart = summary.periodStart else { return false }
                return isSamePeriodStart(periodStart, as: selectedPeriodStart, period: selectedPeriod)
            }

            if !selectedPeriodSummaries.isEmpty {
                podcastBreakdown = Dictionary(grouping: selectedPeriodSummaries.compactMap { summary -> (String, URL?, String, Double)? in
                    let totalSeconds = summary.totalSeconds ?? 0
                    guard totalSeconds > 0 else { return nil }
                    let feed = summary.podcastFeed
                    let feedKey = feed?.absoluteString ?? summary.podcastName ?? "Unknown Podcast"
                    let displayName = summary.podcastName ?? podcasts.first(where: { $0.feed == feed })?.title ?? "Unknown Podcast"
                    return (feedKey, feed, displayName, totalSeconds)
                }, by: \.0)
                .map { _, values in
                    let first = values[0]
                    let feed = first.1
                    let name = first.2
                    return PodcastRollup(
                        podcastName: name,
                        podcastFeed: feed,
                        coverURL: feed.flatMap { podcastCoversByFeed[$0.absoluteString] ?? nil } ?? podcastCoversByTitle[name] ?? nil,
                        totalSeconds: values.reduce(0) { $0 + $1.3 }
                    )
                }
                .sorted { $0.totalSeconds > $1.totalSeconds }
            } else {
                podcastBreakdown = Dictionary(grouping: selectedPeriodRawSessions.compactMap { session -> (String, URL?, String, Double)? in
                    let listenedSeconds = listenedSeconds(for: session)
                    guard listenedSeconds > 0 else { return nil }
                    let feed = session.episode?.podcast?.feed
                    let name = session.podcastName ?? "Unknown Podcast"
                    let key = feed?.absoluteString ?? name
                    return (key, feed, name, listenedSeconds)
                }, by: \.0)
                .map { _, values in
                    let first = values[0]
                    let feed = first.1
                    let name = first.2
                    return PodcastRollup(
                        podcastName: name,
                        podcastFeed: feed,
                        coverURL: feed.flatMap { podcastCoversByFeed[$0.absoluteString] ?? nil } ?? podcastCoversByTitle[name] ?? nil,
                        totalSeconds: values.reduce(0) { $0 + $1.3 }
                    )
                }
                .sorted { $0.totalSeconds > $1.totalSeconds }
            }
        } else {
            podcastBreakdown = []
        }

        let selectedPeriodTotalSeconds = groupedTotals.first(where: {
            isSamePeriodStart($0.start, as: selectedPeriodStart, period: selectedPeriod)
        })?.totalSeconds ?? selectedPeriodSessions.reduce(0) { $0 + $1.listenedSeconds }

        var weekdaySeconds: [Int: Double] = [:]
        var secondsByWeekday = Dictionary(uniqueKeysWithValues: weekdayOrder.map { ($0, Array(repeating: 0.0, count: 24)) })
        let calendar = Calendar.current

        let listeningHabitsStart = selectedPeriod == .day
            ? periodStart(for: selectedPeriodStart, period: .week)
            : selectedPeriodStart
        let listeningHabitsEnd = selectedPeriod == .day
            ? nextPeriodStart(from: listeningHabitsStart, period: .week)
            : selectedPeriodEnd

        let listeningStatsInPeriod = fetchListeningStatsInPeriod(
            selectedPeriodStart: listeningHabitsStart,
            selectedPeriodEnd: listeningHabitsEnd,
            selectedPodcastFeedString: selectedPodcastFeedString,
            selectedPodcastURL: selectedPodcastURL
        )

        if !listeningStatsInPeriod.isEmpty {
            for stat in listeningStatsInPeriod {
                guard let startOfHour = stat.startOfHour, let totalSeconds = stat.totalSeconds, totalSeconds > 0 else { continue }
                accumulateListening(
                    seconds: totalSeconds,
                    on: startOfHour,
                    calendar: calendar,
                    weekdaySeconds: &weekdaySeconds,
                    secondsByWeekday: &secondsByWeekday
                )
            }
        } else {
            let listeningHabitSessions = fetchSessionsInWindow(
                overviewStart: listeningHabitsStart,
                selectedPeriodEnd: listeningHabitsEnd,
                selectedPodcastFeedString: selectedPodcastFeedString
            )

            for session in listeningHabitSessions {
                let listenedSeconds = listenedSeconds(for: session)
                guard listenedSeconds > 0, let startTime = session.startTime else { continue }
                accumulateListening(
                    seconds: listenedSeconds,
                    on: startTime,
                    calendar: calendar,
                    weekdaySeconds: &weekdaySeconds,
                    secondsByWeekday: &secondsByWeekday
                )
            }
        }

        let weekdayTotals = weekdayOrder.enumerated().map { index, weekday in
            WeekdayListeningTotal(
                weekday: weekday,
                label: weekdayLabels[index],
                totalSeconds: weekdaySeconds[weekday] ?? 0
            )
        }
        let heatMap = ListeningHeatMapSnapshot(
            secondsByWeekday: secondsByWeekday,
            maxSeconds: max(secondsByWeekday.values.compactMap { $0.max() }.max() ?? 0, 1)
        )

        snapshot = ListeningHistorySnapshot(
            selectedPodcastTitle: selectedPodcastTitle,
            groupedTotals: groupedTotals,
            chartPoints: chartPoints,
            selectedPeriodTotalSeconds: selectedPeriodTotalSeconds,
            totalListeningSeconds: totalListeningSeconds,
            averagePeriodSeconds: averagePeriodSeconds,
            bestPeriod: groupedTotals.max { $0.totalSeconds < $1.totalSeconds },
            podcastBreakdown: podcastBreakdown,
            selectedPeriodSessions: Array(selectedPeriodSessions),
            weekdayTotals: weekdayTotals,
            heatMap: heatMap,
            isUsingSummaryTotals: !summaryTotals.isEmpty
        )
    }

    private func presentInitialShareGalleryIfNeeded() {
        guard presentShareGalleryOnAppear, didPresentInitialShareGallery == false else { return }
        guard snapshot.podcastBreakdown.isEmpty == false else { return }
        didPresentInitialShareGallery = true
        showInitialShareGallery = true
    }

    private func shareTopPodcasts(as design: TopPodcastShareDesign) {
        let rollups = design.usesAllItems
            ? snapshot.podcastBreakdown
            : Array(snapshot.podcastBreakdown.prefix(design.itemLimit))
        guard !rollups.isEmpty else { return }

        let totalListeningSeconds = snapshot.podcastBreakdown.reduce(0) { $0 + $1.totalSeconds }
        isPreparingPodcastShare = true
        Task {
            let items = await topPodcastShareItems(from: rollups)
            let renderedImage = renderTopPodcastShareImage(
                items: items,
                design: design,
                periodLabel: selectedSharePeriodLabel,
                dateRangeLabel: selectedShareDateRangeLabel,
                totalListeningSeconds: totalListeningSeconds,
                shareTitle: "My Podcasts",
                background: .current,
                renderSize: TopPodcastShareAspect.renderSize(for: TopPodcastShareAspect.defaultVideoSize),
                stats: selectedShareStats,
                durationFormatter: formatDuration
            )
            podcastShareImage = renderedImage
            showPodcastShareSheet = renderedImage != nil
            isPreparingPodcastShare = false
        }
    }

    private func accumulateListening(
        seconds: Double,
        on date: Date,
        calendar: Calendar,
        weekdaySeconds: inout [Int: Double],
        secondsByWeekday: inout [Int: [Double]]
    ) {
        let weekday = calendar.component(.weekday, from: date) - 1
        let hour = calendar.component(.hour, from: date)
        weekdaySeconds[weekday, default: 0] += seconds

        var hours = secondsByWeekday[weekday] ?? Array(repeating: 0, count: 24)
        if hours.indices.contains(hour) {
            hours[hour] += seconds
        }
        secondsByWeekday[weekday] = hours
    }

    @ViewBuilder
    private func summaryCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private var listeningHeatMap: some View {
        let labelColumnWidth: CGFloat = 26
        let columnSpacing: CGFloat = 8
        let rowSpacing: CGFloat = 4
        let headerHeight: CGFloat = 16
        let cellHeight: CGFloat = 12
        let mapHeight = headerHeight + rowSpacing + CGFloat(24) * cellHeight + CGFloat(23) * rowSpacing

        return VStack(alignment: .leading, spacing: 10) {
            Text("Hour By Weekday")
                .font(.subheadline.weight(.semibold))

            GeometryReader { geometry in
                let availableWidth = geometry.size.width - labelColumnWidth - CGFloat(7) * columnSpacing
                let columnWidth = max(18, availableWidth / 7)

                HStack(alignment: .top, spacing: columnSpacing) {
                    VStack(alignment: .trailing, spacing: rowSpacing) {
                        Text("")
                            .font(.caption2)
                            .frame(width: labelColumnWidth, height: headerHeight)
                        ForEach(0..<24, id: \.self) { hour in
                            Text(String(format: "%02d", hour))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: labelColumnWidth, height: cellHeight, alignment: .trailing)
                        }
                    }

                    ForEach(Array(weekdayOrder.enumerated()), id: \.offset) { index, weekday in
                        VStack(spacing: rowSpacing) {
                            Text(weekdayLabels[index])
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: columnWidth, height: headerHeight)

                            ForEach(0..<24, id: \.self) { hour in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(heatColor(for: snapshot.heatMap.seconds(weekday: weekday, hour: hour)))
                                    .frame(width: columnWidth, height: cellHeight)
                            }
                        }
                    }
                }
            }
            .frame(height: mapHeight)

            HStack(spacing: 10) {
                Text("Less")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                LinearGradient(colors: [
                    heatColor(for: 0),
                    heatColor(for: snapshot.heatMap.maxSeconds * 0.35),
                    heatColor(for: snapshot.heatMap.maxSeconds)
                ], startPoint: .leading, endPoint: .trailing)
                .frame(height: 10)
                .clipShape(Capsule())
                Text("More")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func listenedSeconds(for session: PlaySession) -> Double {
        max(0, (session.endTime ?? session.startTime ?? Date()).timeIntervalSince(session.startTime ?? Date()))
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0m" }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func shortDuration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0m" }
        if seconds >= 3600 {
            return String(format: "%.1fh", seconds / 3600)
        }
        return "\(Int((seconds / 60).rounded()))m"
    }

    private func busiestHourLabel(for heatMap: ListeningHeatMapSnapshot) -> String {
        let busiestHour = heatMap.secondsByWeekday.values
            .flatMap { $0.enumerated().map { (hour: $0.offset, seconds: $0.element) } }
            .max { $0.seconds < $1.seconds }

        guard let busiestHour, busiestHour.seconds > 0 else { return "No data yet" }

        var components = DateComponents()
        components.calendar = .autoupdatingCurrent
        components.hour = busiestHour.hour

        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("j")

        guard let date = components.date else {
            return String(format: "%02d:00", busiestHour.hour)
        }
        return formatter.string(from: date)
    }

    private func periodLabel(for date: Date, period: PlaySessionSummaryPeriod) -> String {
        switch period {
        case .day:
            return date.formatted(date: .abbreviated, time: .omitted)
        case .week:
            let end = Calendar.current.date(byAdding: .day, value: 6, to: date) ?? date
            return "\(date.formatted(date: .abbreviated, time: .omitted)) - \(end.formatted(date: .abbreviated, time: .omitted))"
        case .month:
            return date.formatted(.dateTime.month(.wide).year())
        case .year:
            return date.formatted(.dateTime.year())
        }
    }

    private func sharePeriodLabel(for date: Date, period: PlaySessionSummaryPeriod) -> String {
        switch period {
        case .day:
            return date.formatted(date: .abbreviated, time: .omitted)
        case .week:
            let calendar = Calendar.autoupdatingCurrent
            let components = calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: date)
            let week = components.weekOfYear ?? 0
            let year = components.yearForWeekOfYear ?? calendar.component(.year, from: date)
            return "Week \(week), \(year)"
        case .month:
            return date.formatted(.dateTime.month(.wide).year())
        case .year:
            return date.formatted(.dateTime.year())
        }
    }

    private func periodDateRangeLabel(for date: Date, period: PlaySessionSummaryPeriod) -> String {
        let calendar = Calendar.current
        let start = periodStart(for: date, period: period)
        let exclusivePeriodEnd = nextPeriodStart(from: start, period: period)
        let inclusivePeriodEnd = calendar.date(byAdding: .day, value: -1, to: exclusivePeriodEnd) ?? exclusivePeriodEnd
        let end = min(inclusivePeriodEnd, calendar.startOfDay(for: Date()))

        if calendar.isDate(start, inSameDayAs: end) {
            return localizedDateString(for: start)
        }

        let formatter = DateIntervalFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: start, to: end)
    }

    private func localizedDateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func periodStart(for date: Date, period: PlaySessionSummaryPeriod) -> Date {
        let calendar = Calendar.current
        switch period {
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return calendar.date(from: components) ?? calendar.startOfDay(for: date)
        case .month:
            let components = calendar.dateComponents([.year, .month], from: date)
            return calendar.date(from: components) ?? calendar.startOfDay(for: date)
        case .year:
            let components = calendar.dateComponents([.year], from: date)
            return calendar.date(from: components) ?? calendar.startOfDay(for: date)
        }
    }

    private func nextPeriodStart(from date: Date, period: PlaySessionSummaryPeriod) -> Date {
        let calendar = Calendar.current
        let unit: Calendar.Component
        switch period {
        case .day:
            unit = .day
        case .week:
            unit = .weekOfYear
        case .month:
            unit = .month
        case .year:
            unit = .year
        }

        let next = calendar.date(byAdding: unit, value: 1, to: date) ?? date
        return periodStart(for: next, period: period)
    }

    private func moveSelectedPeriod(by amount: Int) {
        let calendar = Calendar.current
        let unit: Calendar.Component
        switch selectedPeriod {
        case .day:
            unit = .day
        case .week:
            unit = .weekOfYear
        case .month:
            unit = .month
        case .year:
            unit = .year
        }

        guard let updated = calendar.date(byAdding: unit, value: amount, to: selectedPeriodStart) else { return }
        selectedPeriodStart = periodStart(for: updated, period: selectedPeriod)
    }

    private func periodStartByAdding(_ value: Int, to date: Date, period: PlaySessionSummaryPeriod) -> Date {
        let calendar = Calendar.current
        let unit: Calendar.Component
        switch period {
        case .day:
            unit = .day
        case .week:
            unit = .weekOfYear
        case .month:
            unit = .month
        case .year:
            unit = .year
        }

        let shifted = calendar.date(byAdding: unit, value: value, to: date) ?? date
        return periodStart(for: shifted, period: period)
    }

    private func overviewPeriodCount(for period: PlaySessionSummaryPeriod) -> Int {
        switch period {
        case .day:
            return 120
        case .week:
            return 104
        case .month:
            return 60
        case .year:
            return 20
        }
    }

    private func hasAnySummary() -> Bool {
        var descriptor = FetchDescriptor<PlaySessionSummary>()
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
    }

    private func hasAnySession() -> Bool {
        var descriptor = FetchDescriptor<PlaySession>()
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
    }

    private func fetchSummariesInWindow(
        period: PlaySessionSummaryPeriod,
        overviewStart: Date,
        selectedPeriodEnd: Date,
        selectedPodcastFeedString: String?,
        selectedPodcastURL: URL?,
        lookbackPeriods: Int
    ) -> [PlaySessionSummary] {
        let periodRawValue = period.rawValue

        let primary: [PlaySessionSummary] = {
            let predicate: Predicate<PlaySessionSummary>
            if let selectedPodcastURL {
                predicate = #Predicate<PlaySessionSummary> { summary in
                    summary.periodKind == periodRawValue
                    && summary.periodStart != nil
                    && summary.periodStart! >= overviewStart
                    && summary.periodStart! < selectedPeriodEnd
                    && summary.podcastFeed == selectedPodcastURL
                }
            } else {
                predicate = #Predicate<PlaySessionSummary> { summary in
                    summary.periodKind == periodRawValue
                    && summary.periodStart != nil
                    && summary.periodStart! >= overviewStart
                    && summary.periodStart! < selectedPeriodEnd
                }
            }
            let descriptor = FetchDescriptor<PlaySessionSummary>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.periodStart, order: .reverse)]
            )
            return (try? modelContext.fetch(descriptor)) ?? []
        }()

        if !primary.isEmpty {
            return primary
        }

        let fallbackDescriptor = FetchDescriptor<PlaySessionSummary>(
            sortBy: [SortDescriptor(\.periodStart, order: .reverse)]
        )
        let fallback = (try? modelContext.fetch(fallbackDescriptor)) ?? []
        return fallback.filter { summary in
            guard
                summary.periodKind == periodRawValue,
                let start = summary.periodStart,
                start >= overviewStart,
                start < selectedPeriodEnd
            else { return false }

            if let selectedPodcastFeedString {
                return summary.podcastFeed?.absoluteString == selectedPodcastFeedString
            }
            return true
        }
    }

    private func fetchSessionsInWindow(
        overviewStart: Date,
        selectedPeriodEnd: Date,
        selectedPodcastFeedString: String?
    ) -> [PlaySession] {
        let primary: [PlaySession] = {
            let predicate = #Predicate<PlaySession> { session in
                session.startTime != nil
                && session.startTime! >= overviewStart
                && session.startTime! < selectedPeriodEnd
            }
            var descriptor = FetchDescriptor<PlaySession>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.startTime, order: .reverse)]
            )
            descriptor.fetchLimit = 2500
            return (try? modelContext.fetch(descriptor)) ?? []
        }()

        let applyPodcastFilter: ([PlaySession]) -> [PlaySession] = { sessions in
            sessions.filter { session in
                selectedPodcastFeedString == nil || session.episode?.podcast?.feed?.absoluteString == selectedPodcastFeedString
            }
        }

        if !primary.isEmpty {
            return applyPodcastFilter(primary)
        }

        var fallbackDescriptor = FetchDescriptor<PlaySession>(
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        fallbackDescriptor.fetchLimit = 5000
        let fallback = (try? modelContext.fetch(fallbackDescriptor)) ?? []
        return applyPodcastFilter(
            fallback.filter { session in
                guard let start = session.startTime else { return false }
                return start >= overviewStart && start < selectedPeriodEnd
            }
        )
    }

    private func fetchListeningStatsInPeriod(
        selectedPeriodStart: Date,
        selectedPeriodEnd: Date,
        selectedPodcastFeedString: String?,
        selectedPodcastURL: URL?
    ) -> [ListeningStat] {
        let primary: [ListeningStat] = {
            let predicate: Predicate<ListeningStat>
            if let selectedPodcastURL {
                predicate = #Predicate<ListeningStat> { stat in
                    stat.startOfHour != nil
                    && stat.startOfHour! >= selectedPeriodStart
                    && stat.startOfHour! < selectedPeriodEnd
                    && stat.podcastFeed == selectedPodcastURL
                }
            } else {
                predicate = #Predicate<ListeningStat> { stat in
                    stat.startOfHour != nil
                    && stat.startOfHour! >= selectedPeriodStart
                    && stat.startOfHour! < selectedPeriodEnd
                }
            }
            let descriptor = FetchDescriptor<ListeningStat>(predicate: predicate)
            return (try? modelContext.fetch(descriptor)) ?? []
        }()

        if !primary.isEmpty {
            return primary
        }

        var fallbackDescriptor = FetchDescriptor<ListeningStat>(
            sortBy: [SortDescriptor(\.startOfHour, order: .reverse)]
        )
        fallbackDescriptor.fetchLimit = 24 * 90
        let fallback = (try? modelContext.fetch(fallbackDescriptor)) ?? []
        return fallback.filter { stat in
            guard let hour = stat.startOfHour, hour >= selectedPeriodStart, hour < selectedPeriodEnd else {
                return false
            }
            if let selectedPodcastFeedString {
                return stat.podcastFeed?.absoluteString == selectedPodcastFeedString
            }
            return true
        }
    }

    private func isSamePeriodStart(_ lhs: Date, as rhs: Date, period: PlaySessionSummaryPeriod) -> Bool {
        let calendar = Calendar.current
        switch period {
        case .day:
            return calendar.isDate(lhs, inSameDayAs: rhs)
        case .week:
            return calendar.isDate(lhs, equalTo: rhs, toGranularity: .weekOfYear)
        case .month:
            return calendar.isDate(lhs, equalTo: rhs, toGranularity: .month)
        case .year:
            return calendar.isDate(lhs, equalTo: rhs, toGranularity: .year)
        }
    }

    private func heatColor(for seconds: Double) -> Color {
        let intensity = min(max(seconds / snapshot.heatMap.maxSeconds, 0), 1)
        return Color.accentColor.opacity(0.12 + intensity * 0.88)
    }
}

private struct RecentListeningSessionRow: View {
    let session: RecentListeningSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.episodeTitle)
                        .font(.headline)
                    Text(session.podcastName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Self.formatDuration(session.listenedSeconds))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }

            HStack {
                Text(session.startTime, format: .dateTime.month().day().hour().minute())
                Spacer()
                Text(session.endedCleanly ? "Ended cleanly" : "Recovered / interrupted")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let startPosition = session.startPosition, let endPosition = session.endPosition {
                Text("From \(Self.formatTimestamp(startPosition)) to \(Self.formatTimestamp(endPosition))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private static func formatTimestamp(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0m" }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

private struct ListeningSessionsListView: View {
    let sessions: [RecentListeningSession]
    let title: String
    let subtitle: String

    var body: some View {
        List {
            Section {
                ForEach(sessions) { session in
                    RecentListeningSessionRow(session: session)
                }
            } header: {
                Text(subtitle)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TopPodcastShareGalleryView: View {
    let rollups: [PodcastRollup]
    let periodLabel: String
    let dateRangeLabel: String
    let stats: TopPodcastShareStats

    @State private var renderedImages: [TopPodcastShareDesign: UIImage] = [:]
    @State private var selectedDesigns: Set<TopPodcastShareDesign> = []
    @State private var shareActivityItems: [Any] = []
    @State private var shareTempFileURLs: [URL] = []
    @State private var shareSheetID = UUID()
    @State private var showShareSheet = false
    @State private var isRendering = false
    @State private var shareTitle = "My Podcasts"
    @State private var selectedBackground: TopPodcastShareBackground = .current
    @State private var selectedVideoSize = TopPodcastShareAspect.defaultVideoSize

    private var availableDesigns: [TopPodcastShareDesign] {
        TopPodcastShareDesign.allCases.filter { rollups.count >= $0.minimumItemCount }
    }

    private var effectiveShareTitle: String {
        let trimmed = shareTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "My Podcasts" : trimmed
    }

    private var renderSignature: String {
        let rollupSignature = rollups.map { "\($0.id):\($0.totalSeconds)" }.joined(separator: "|")
        return "\(effectiveShareTitle)|\(selectedBackground.rawValue)|\(selectedVideoSize.width)x\(selectedVideoSize.height)|\(periodLabel)|\(dateRangeLabel)|\(stats.renderSignature)|\(rollupSignature)"
    }

    private var renderSize: CGSize {
        TopPodcastShareAspect.renderSize(for: selectedVideoSize)
    }

    private var previewAspectRatio: CGFloat {
        TopPodcastShareAspect.aspectRatio(for: selectedVideoSize)
    }

    private var shareDesignGridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
    }

    private var canShareSelectedDesigns: Bool {
        selectedDesigns.isEmpty == false && selectedDesigns.contains { renderedImages[$0] == nil } == false
    }

    var body: some View {
        List {
            if rollups.isEmpty {
                ContentUnavailableView(
                    "No Share Pictures",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Top podcast share pictures are available when the statistics show all podcasts.")
                )
            } else {
                Section {
                    NavigationLink {
                        TopPodcastShareCustomizeView(
                            title: $shareTitle,
                            selectedBackground: $selectedBackground,
                            selectedVideoSize: $selectedVideoSize
                        )
                    } label: {
                        Label("Customize", systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text("Title: \(effectiveShareTitle) • Background: \(selectedBackground.title)")
                }

                Section {
                    LazyVGrid(columns: shareDesignGridColumns, spacing: 12) {
                        ForEach(availableDesigns) { design in
                            TopPodcastSharePreviewTile(
                                design: design,
                                image: renderedImages[design],
                                aspectRatio: previewAspectRatio,
                                isSelected: selectedDesigns.contains(design),
                                isRendering: isRendering
                            ) {
                                toggleSelection(for: design)
                            } shareAction: {
                                share(designs: [design])
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Designs")
                } footer: {
                    Text(dateRangeLabel)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
        .navigationTitle("Share Top Podcasts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    share(designs: Array(selectedDesigns))
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(canShareSelectedDesigns == false)
                .accessibilityLabel(selectedDesigns.count <= 1 ? "Share Selected Image" : "Share Selected Images")
            }
        }
        .task(id: renderSignature) {
            await renderPreviews()
        }
        .sheet(isPresented: $showShareSheet, onDismiss: cleanUpShareTemporaryFiles) {
            ShareSheet(activityItems: shareActivityItems)
                .id(shareSheetID)
        }
    }

    private func toggleSelection(for design: TopPodcastShareDesign) {
        if selectedDesigns.contains(design) {
            selectedDesigns.remove(design)
        } else {
            selectedDesigns.insert(design)
        }
    }

    private func share(designs: [TopPodcastShareDesign]) {
        let items = designs.compactMap { design -> (TopPodcastShareDesign, UIImage)? in
            guard let image = renderedImages[design] else { return nil }
            return (design, image)
        }
        guard !items.isEmpty else { return }

        if let fileURLs = writeShareImagesToTemporaryFiles(items) {
            shareTempFileURLs = fileURLs
            shareActivityItems = fileURLs
        } else {
            shareTempFileURLs = []
            shareActivityItems = items.map(\.1)
        }
        shareSheetID = UUID()
        showShareSheet = true
    }

    private func writeShareImagesToTemporaryFiles(_ items: [(TopPodcastShareDesign, UIImage)]) -> [URL]? {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("UpNextSharePics", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return try items.enumerated().map { index, item in
                guard let data = item.1.pngData() else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let filename = "\(index + 1)-\(shareFilenameComponent(for: item.0)).png"
                let url = directory.appendingPathComponent(filename)
                try data.write(to: url, options: .atomic)
                return url
            }
        } catch {
            try? fileManager.removeItem(at: directory)
            return nil
        }
    }

    private func shareFilenameComponent(for design: TopPodcastShareDesign) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let words = design.title
            .lowercased()
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
        return words.joined(separator: "-")
    }

    private func cleanUpShareTemporaryFiles() {
        let directories = Set(shareTempFileURLs.map { $0.deletingLastPathComponent() })
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        shareTempFileURLs = []
        shareActivityItems = []
    }

    @MainActor
    private func renderPreviews() async {
        guard !rollups.isEmpty else {
            renderedImages = [:]
            selectedDesigns = []
            return
        }

        isRendering = true
        let neededDesigns = availableDesigns
        let shouldLoadAllItems = neededDesigns.contains { $0.usesAllItems }
        let maxLimit = neededDesigns
            .filter { !$0.usesAllItems }
            .map(\.itemLimit)
            .max() ?? 0
        let sourceRollups = shouldLoadAllItems ? rollups : Array(rollups.prefix(maxLimit))
        let items = await topPodcastShareItems(from: sourceRollups)
        let totalListeningSeconds = rollups.reduce(0) { $0 + $1.totalSeconds }

        var images: [TopPodcastShareDesign: UIImage] = [:]
        for design in neededDesigns {
            let designItems = design.usesAllItems ? items : Array(items.prefix(design.itemLimit))
            images[design] = renderTopPodcastShareImage(
                items: designItems,
                design: design,
                periodLabel: periodLabel,
                dateRangeLabel: dateRangeLabel,
                totalListeningSeconds: totalListeningSeconds,
                shareTitle: effectiveShareTitle,
                background: selectedBackground,
                renderSize: renderSize,
                stats: stats,
                durationFormatter: formatDuration
            )
        }

        renderedImages = images
        selectedDesigns = selectedDesigns.intersection(Set(neededDesigns))
        isRendering = false
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0m" }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

private struct TopPodcastShareCustomizeView: View {
    @Binding var title: String
    @Binding var selectedBackground: TopPodcastShareBackground
    @Binding var selectedVideoSize: CGSize

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $title)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)

                Button("Reset to Default") {
                    title = "My Podcasts"
                }
            } header: {
                Text("Share Picture Title")
            } footer: {
                Text("This title is used for every share picture preview and export.")
            }

            Section {
                VideoSizePicker(videoSize: $selectedVideoSize)
            } header: {
                Text("Aspect Ratio")
            } footer: {
                Text("The selected ratio is applied to every share picture preview and export.")
            }

            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                    ForEach(TopPodcastShareBackground.allCases) { background in
                        Button {
                            selectedBackground = background
                        } label: {
                            TopPodcastShareBackgroundOption(
                                background: background,
                                isSelected: selectedBackground == background
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Background")
            } footer: {
                Text("Background changes are applied to every share picture preview and export.")
            }
        }
        .navigationTitle("Customize")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TopPodcastShareBackgroundOption: View {
    let background: TopPodcastShareBackground
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TopPodcastShareBackgroundPreview(background: background)
                .frame(height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 3 : 1)
                )

            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(background.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

private struct TopPodcastShareBackgroundPreview: View {
    let background: TopPodcastShareBackground

    var body: some View {
        return ZStack {
            if let occasionConfig = background.occasionConfig {
                SeasonalPodcastShareBackground(config: occasionConfig)
            } else if let month = background.seasonalMonth {
                SeasonalPodcastShareBackground(month: month)
            } else {
                switch background {
                case .current:
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.09, blue: 0.15),
                        Color(red: 0.04, green: 0.18, blue: 0.22),
                        Color(red: 0.47, green: 0.17, blue: 0.12)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                case .stripes:
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            ForEach(Array(TopPodcastShareBackground.stripeColors.enumerated()), id: \.offset) { _, color in
                                color
                                    .frame(height: geometry.size.height / CGFloat(TopPodcastShareBackground.stripeColors.count))
                            }
                        }
                    }
                case .rainbowGradient:
                    LinearGradient(
                        colors: TopPodcastShareBackground.stripeColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                case .white:
                    Color.white
                case .black:
                    Color.black
                default:
                    Color.black
                }
            }
        }
    }
}

private struct SeasonalPodcastShareBackground: View {
    let config: SeasonalBackgroundConfig

    init(month: Int) {
        self.config = SeasonalBackgroundConfig.config(for: month)
    }

    init(config: SeasonalBackgroundConfig) {
        self.config = config
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: config.baseColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.black.opacity(config.centerDimming),
                    Color.black.opacity(config.centerDimming * 0.62),
                    Color.clear
                ],
                center: .center,
                startRadius: 40,
                endRadius: 780
            )

            GeometryReader { geometry in
                ZStack {
                    seasonalScene(in: geometry.size)
                }
            }
        }
    }

    @ViewBuilder
    private func seasonalScene(in size: CGSize) -> some View {
        switch config.kind {
        case .winter:
            winterScene(in: size)
        case .frost:
            frostScene(in: size)
        case .spring:
            springScene(in: size)
        case .meadow:
            meadowScene(in: size)
        case .summer:
            summerScene(in: size)
        case .beach:
            beachScene(in: size)
        case .autumn:
            autumnScene(in: size)
        case .harvest:
            harvestScene(in: size)
        case .rain:
            rainScene(in: size)
        case .festive:
            festiveScene(in: size)
        case .fireworks:
            fireworksScene(in: size)
        case .confetti:
            confettiScene(in: size)
        case .easter:
            easterScene(in: size)
        case .crescent:
            crescentScene(in: size)
        case .lanterns:
            lanternScene(in: size)
        case .candles:
            candleScene(in: size)
        case .colorClouds:
            colorCloudScene(in: size)
        case .diyas:
            diyaScene(in: size)
        case .midsummer:
            midsummerScene(in: size)
        case .halloween:
            halloweenScene(in: size)
        case .christmasTrees:
            christmasTreeScene(in: size)
        }
    }

    private func frostScene(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<18, id: \.self) { index in
                snowflake(index: index, in: size)
            }

            ForEach(0..<5, id: \.self) { index in
                frostMountain(index: index, in: size)
            }

            bottomDrift(size: size, color: Color.white.opacity(0.26), height: 0.18, yOffset: 0.10)
        }
    }

    private func winterScene(in size: CGSize) -> some View {
        ZStack {
            decorativeOrb(size: size, color: config.accentColors[0], x: 0.18, y: 0.14, diameter: 0.16)
                .opacity(0.36)

            ForEach(0..<34, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(index % 3 == 0 ? 0.78 : 0.46))
                    .frame(width: snowSize(index), height: snowSize(index))
                    .position(edgePoint(index: index, in: size, topBias: 0.78))
            }

            bottomDrift(size: size, color: config.accentColors[1].opacity(0.42), height: 0.22, yOffset: 0.06)
            bottomDrift(size: size, color: Color.white.opacity(0.24), height: 0.16, yOffset: 0.10)
        }
    }

    private func springScene(in size: CGSize) -> some View {
        ZStack {
            decorativeOrb(size: size, color: config.accentColors[0], x: 0.84, y: 0.13, diameter: 0.15)
                .opacity(0.34)

            ForEach(0..<18, id: \.self) { index in
                flower(index: index, size: flowerSize(index), color: config.accentColors[index % config.accentColors.count])
                    .position(bottomSidePoint(index: index, in: size))
            }

            ForEach(0..<12, id: \.self) { index in
                Capsule()
                    .fill(config.accentColors[1].opacity(0.26))
                    .frame(width: max(size.width * 0.006, 4), height: max(size.height * 0.12, 50))
                    .rotationEffect(.degrees(Double(index % 2 == 0 ? -10 : 12)))
                    .position(x: size.width * sideX(index), y: size.height * (0.80 + CGFloat(index % 4) * 0.045))
            }

            bottomDrift(size: size, color: config.accentColors[2].opacity(0.22), height: 0.18, yOffset: 0.08)
        }
    }

    private func meadowScene(in size: CGSize) -> some View {
        ZStack {
            decorativeOrb(size: size, color: config.accentColors[0], x: 0.18, y: 0.15, diameter: 0.18)
                .opacity(0.30)

            ForEach(0..<26, id: \.self) { index in
                flower(index: index, size: flowerSize(index) * 1.08, color: config.accentColors[index % config.accentColors.count])
                    .position(bottomSidePoint(index: index + 4, in: size))
            }

            ForEach(0..<18, id: \.self) { index in
                grassBlade(index: index, in: size)
            }

            bottomDrift(size: size, color: config.accentColors[1].opacity(0.28), height: 0.19, yOffset: 0.09)
        }
    }

    private func summerScene(in size: CGSize) -> some View {
        ZStack {
            Circle()
                .fill(config.accentColors[0].opacity(0.78))
                .frame(width: size.shortSide * 0.18, height: size.shortSide * 0.18)
                .position(x: size.width * 0.82, y: size.height * 0.16)

            ForEach(0..<3, id: \.self) { index in
                summerWave(index: index, in: size)
            }

            bottomDrift(size: size, color: config.accentColors.last?.opacity(0.36) ?? .white.opacity(0.28), height: 0.16, yOffset: 0.11)
        }
    }

    private func beachScene(in size: CGSize) -> some View {
        ZStack {
            Circle()
                .fill(config.accentColors[0].opacity(0.84))
                .frame(width: size.shortSide * 0.20, height: size.shortSide * 0.20)
                .position(x: size.width * 0.82, y: size.height * 0.15)

            ForEach(0..<4, id: \.self) { index in
                summerWave(index: index, in: size)
            }

            WaveShape(phase: 0.42)
                .fill(config.accentColors[3].opacity(0.54))
                .frame(width: size.width * 1.16, height: size.height * 0.20)
                .position(x: size.width * 0.50, y: size.height * 0.93)

            ForEach(0..<3, id: \.self) { index in
                beachUmbrella(index: index, in: size)
            }
        }
    }

    private func autumnScene(in size: CGSize) -> some View {
        ZStack {
            decorativeOrb(size: size, color: config.accentColors[0], x: 0.16, y: 0.15, diameter: 0.17)
                .opacity(0.30)

            ForEach(0..<30, id: \.self) { index in
                LeafShape()
                    .fill(config.accentColors[index % config.accentColors.count].opacity(0.72))
                    .frame(width: leafSize(index), height: leafSize(index) * 1.42)
                    .rotationEffect(.degrees(Double((index * 37) % 120) - 60))
                    .position(autumnPoint(index: index, in: size))
            }

            bottomDrift(size: size, color: config.accentColors[1].opacity(0.24), height: 0.18, yOffset: 0.09)
        }
    }

    private func harvestScene(in size: CGSize) -> some View {
        ZStack {
            decorativeOrb(size: size, color: config.accentColors[0], x: 0.83, y: 0.16, diameter: 0.18)
                .opacity(0.32)

            ForEach(0..<26, id: \.self) { index in
                grainStalk(index: index, in: size)
            }

            bottomDrift(size: size, color: config.accentColors[1].opacity(0.26), height: 0.18, yOffset: 0.09)
        }
    }

    private func rainScene(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                cloud(index: index, size: size)
                    .position(x: size.width * (0.14 + CGFloat(index) * 0.24), y: size.height * (index % 2 == 0 ? 0.13 : 0.20))
                    .opacity(0.32)
            }

            ForEach(0..<28, id: \.self) { index in
                Capsule()
                    .fill(config.accentColors[index % config.accentColors.count].opacity(0.40))
                    .frame(width: max(size.shortSide * 0.006, 4), height: max(size.shortSide * 0.05, 16))
                    .rotationEffect(.degrees(16))
                    .position(edgePoint(index: index, in: size, topBias: 0.72))
            }

            bottomDrift(size: size, color: config.accentColors[0].opacity(0.20), height: 0.16, yOffset: 0.10)
        }
    }

    private func festiveScene(in size: CGSize) -> some View {
        ZStack {
            winterScene(in: size)

            ForEach(0..<18, id: \.self) { index in
                Circle()
                    .fill(config.accentColors[index % config.accentColors.count].opacity(0.86))
                    .frame(width: lightSize(index), height: lightSize(index))
                    .shadow(color: config.accentColors[index % config.accentColors.count].opacity(0.8), radius: 10)
                    .position(x: size.width * (0.04 + CGFloat(index) / 17 * 0.92), y: size.height * (index % 2 == 0 ? 0.09 : 0.15))
            }
        }
    }

    private func christmasTreeScene(in size: CGSize) -> some View {
        ZStack {
            winterScene(in: size).opacity(0.74)

            ForEach(0..<4, id: \.self) { index in
                christmasTree(index: index, in: size)
            }

            ForEach(0..<20, id: \.self) { index in
                Circle()
                    .fill(config.accentColors[index % config.accentColors.count].opacity(0.82))
                    .frame(width: lightSize(index), height: lightSize(index))
                    .shadow(color: config.accentColors[index % config.accentColors.count].opacity(0.7), radius: 8)
                    .position(edgePoint(index: index + 45, in: size, topBias: 0.70))
            }
        }
    }

    private func fireworksScene(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<7, id: \.self) { index in
                burst(index: index, in: size)
            }
            confettiScene(in: size).opacity(0.36)
        }
    }

    private func confettiScene(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<42, id: \.self) { index in
                Capsule()
                    .fill(config.accentColors[index % config.accentColors.count].opacity(0.74))
                    .frame(width: confettiWidth(index), height: confettiHeight(index))
                    .rotationEffect(.degrees(Double((index * 31) % 160) - 80))
                    .position(edgePoint(index: index, in: size, topBias: 0.68))
            }
            bottomDrift(size: size, color: config.accentColors[0].opacity(0.18), height: 0.16, yOffset: 0.10)
        }
    }

    private func easterScene(in size: CGSize) -> some View {
        ZStack {
            springScene(in: size)
            ForEach(0..<8, id: \.self) { index in
                EggShape()
                    .fill(config.accentColors[index % config.accentColors.count].opacity(0.72))
                    .frame(width: eggSize(index) * 0.72, height: eggSize(index))
                    .rotationEffect(.degrees(Double((index * 23) % 34) - 17))
                    .position(bottomSidePoint(index: index + 6, in: size))
            }
        }
    }

    private func crescentScene(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<20, id: \.self) { index in
                star(index: index, in: size)
            }
            CrescentShape()
                .fill(config.accentColors[0].opacity(0.86))
                .frame(width: size.shortSide * 0.18, height: size.shortSide * 0.18)
                .position(x: size.width * 0.84, y: size.height * 0.16)
            bottomDrift(size: size, color: config.accentColors[1].opacity(0.18), height: 0.16, yOffset: 0.10)
        }
    }

    private func lanternScene(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<7, id: \.self) { index in
                lantern(index: index, in: size)
            }
            ForEach(0..<18, id: \.self) { index in
                star(index: index, in: size).opacity(0.7)
            }
        }
    }

    private func candleScene(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<18, id: \.self) { index in
                star(index: index, in: size).opacity(0.5)
            }
            HStack(alignment: .bottom, spacing: size.shortSide * 0.018) {
                ForEach(0..<9, id: \.self) { index in
                    candle(index: index, height: size.shortSide * (0.14 + CGFloat(index % 3) * 0.025))
                }
            }
            .position(x: size.width * 0.5, y: size.height * 0.86)
        }
    }

    private func colorCloudScene(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<20, id: \.self) { index in
                Circle()
                    .fill(config.accentColors[index % config.accentColors.count].opacity(0.40))
                    .frame(width: colorCloudSize(index), height: colorCloudSize(index))
                    .blur(radius: colorCloudSize(index) * 0.18)
                    .position(autumnPoint(index: index, in: size))
            }
        }
    }

    private func diyaScene(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<22, id: \.self) { index in
                star(index: index, in: size)
            }
            ForEach(0..<7, id: \.self) { index in
                DiyaShape()
                    .fill(config.accentColors[index % config.accentColors.count].opacity(0.82))
                    .frame(width: size.shortSide * 0.09, height: size.shortSide * 0.052)
                    .position(x: size.width * (0.08 + CGFloat(index) / 6 * 0.84), y: size.height * (index % 2 == 0 ? 0.84 : 0.91))
            }
        }
    }

    private func midsummerScene(in size: CGSize) -> some View {
        ZStack {
            summerScene(in: size)
            ForEach(0..<16, id: \.self) { index in
                flower(index: index, size: flowerSize(index) * 0.95, color: config.accentColors[index % config.accentColors.count])
                    .position(bottomSidePoint(index: index, in: size))
            }
        }
    }

    private func halloweenScene(in size: CGSize) -> some View {
        ZStack {
            autumnScene(in: size)
            Circle()
                .fill(config.accentColors[0].opacity(0.60))
                .frame(width: size.shortSide * 0.17, height: size.shortSide * 0.17)
                .position(x: size.width * 0.84, y: size.height * 0.15)
            ForEach(0..<10, id: \.self) { index in
                Capsule()
                    .fill(config.accentColors[2].opacity(0.42))
                    .frame(width: batWidth(index), height: max(batWidth(index) * 0.26, 6))
                    .rotationEffect(.degrees(Double((index * 29) % 50) - 25))
                    .position(edgePoint(index: index + 20, in: size, topBias: 0.92))
            }
        }
    }

    private func flower(index: Int, size: CGFloat, color: Color) -> some View {
        ZStack {
            ForEach(0..<5, id: \.self) { petal in
                Capsule()
                    .fill(color.opacity(0.72))
                    .frame(width: size * 0.36, height: size * 0.72)
                    .offset(y: -size * 0.24)
                    .rotationEffect(.degrees(Double(petal) * 72))
            }
            Circle()
                .fill(config.accentColors[0].opacity(0.92))
                .frame(width: size * 0.26, height: size * 0.26)
        }
    }

    private func cloud(index: Int, size: CGSize) -> some View {
        let cloudWidth = size.shortSide * (0.18 + CGFloat(index % 2) * 0.04)
        return ZStack {
            Capsule()
                .fill(Color.white.opacity(0.36))
                .frame(width: cloudWidth, height: cloudWidth * 0.34)
            Circle()
                .fill(Color.white.opacity(0.34))
                .frame(width: cloudWidth * 0.42, height: cloudWidth * 0.42)
                .offset(x: -cloudWidth * 0.20, y: -cloudWidth * 0.10)
            Circle()
                .fill(Color.white.opacity(0.30))
                .frame(width: cloudWidth * 0.50, height: cloudWidth * 0.50)
                .offset(x: cloudWidth * 0.12, y: -cloudWidth * 0.14)
        }
    }

    private func burst(index: Int, in size: CGSize) -> some View {
        let burstSize = size.shortSide * (0.10 + CGFloat(index % 3) * 0.025)
        let center = edgePoint(index: index + 12, in: size, topBias: 0.88)

        return ZStack {
            ForEach(0..<10, id: \.self) { ray in
                burstRay(index: index, ray: ray, burstSize: burstSize)
            }
            Circle()
                .fill(config.accentColors[index % config.accentColors.count].opacity(0.88))
                .frame(width: burstSize * 0.16, height: burstSize * 0.16)
        }
        .position(center)
    }

    private func burstRay(index: Int, ray: Int, burstSize: CGFloat) -> some View {
        let color = config.accentColors[(index + ray) % config.accentColors.count].opacity(0.78)
        let rayWidth = max(burstSize * 0.07, 3)
        let rayHeight = burstSize * 0.42
        let offset = -burstSize * 0.24
        let rotation = Double(ray) * 36

        return Capsule()
            .fill(color)
            .frame(width: rayWidth, height: rayHeight)
            .offset(y: offset)
            .rotationEffect(.degrees(rotation))
    }

    private func star(index: Int, in size: CGSize) -> some View {
        StarShape(points: index % 3 == 0 ? 8 : 5)
            .fill(config.accentColors[index % config.accentColors.count].opacity(index % 4 == 0 ? 0.76 : 0.48))
            .frame(width: starSize(index), height: starSize(index))
            .position(edgePoint(index: index + 30, in: size, topBias: 0.82))
    }

    private func lantern(index: Int, in size: CGSize) -> some View {
        let lanternWidth = size.shortSide * (0.060 + CGFloat(index % 3) * 0.010)
        let color = config.accentColors[index % config.accentColors.count]
        let x = size.width * (0.10 + CGFloat(index) / 6 * 0.80)
        let y = size.height * (index % 2 == 0 ? 0.12 : 0.21)

        return VStack(spacing: 0) {
            Rectangle()
                .fill(color.opacity(0.58))
                .frame(width: 2, height: size.shortSide * 0.08)
            RoundedRectangle(cornerRadius: lanternWidth * 0.28, style: .continuous)
                .fill(color.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: lanternWidth * 0.28, style: .continuous)
                        .stroke(config.accentColors[0].opacity(0.54), lineWidth: 2)
                )
                .frame(width: lanternWidth, height: lanternWidth * 1.18)
                .shadow(color: color.opacity(0.74), radius: 14)
        }
        .position(x: x, y: y)
    }

    private func candle(index: Int, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            FlameShape()
                .fill(config.accentColors[2].opacity(0.92))
                .frame(width: height * 0.24, height: height * 0.30)
                .shadow(color: config.accentColors[2].opacity(0.72), radius: 10)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(config.accentColors[index % 2].opacity(0.72))
                .frame(width: height * 0.22, height: height)
        }
    }

    private func snowflake(index: Int, in size: CGSize) -> some View {
        let flakeSize = size.shortSide * (0.030 + CGFloat(index % 4) * 0.008)
        return ZStack {
            ForEach(0..<3, id: \.self) { ray in
                Capsule()
                    .fill(config.accentColors[index % config.accentColors.count].opacity(0.58))
                    .frame(width: max(flakeSize * 0.10, 2), height: flakeSize)
                    .rotationEffect(.degrees(Double(ray) * 60))
            }
        }
        .position(edgePoint(index: index + 9, in: size, topBias: 0.82))
    }

    private func frostMountain(index: Int, in size: CGSize) -> some View {
        let color = config.accentColors[index % config.accentColors.count].opacity(0.22 + Double(index) * 0.045)
        let width = size.width * (0.30 + CGFloat(index % 2) * 0.08)
        let height = size.height * (0.22 + CGFloat(index % 3) * 0.04)
        let x = size.width * (0.08 + CGFloat(index) * 0.22)

        return MountainShape()
            .fill(color)
            .frame(width: width, height: height)
            .position(x: x, y: size.height * 0.86)
    }

    private func grassBlade(index: Int, in size: CGSize) -> some View {
        let height = size.height * (0.10 + CGFloat(index % 5) * 0.014)
        return Capsule()
            .fill(config.accentColors[1].opacity(0.34))
            .frame(width: max(size.shortSide * 0.007, 4), height: height)
            .rotationEffect(.degrees(Double(index % 2 == 0 ? -13 : 15)))
            .position(x: size.width * sideX(index + 3), y: size.height * (0.84 + CGFloat(index % 4) * 0.035))
    }

    private func grainStalk(index: Int, in size: CGSize) -> some View {
        let height = size.height * (0.12 + CGFloat(index % 4) * 0.018)
        return ZStack {
            Capsule()
                .fill(config.accentColors[0].opacity(0.46))
                .frame(width: max(size.shortSide * 0.006, 3), height: height)
            ForEach(0..<3, id: \.self) { grain in
                grainKernel(grain: grain, height: height)
            }
        }
        .rotationEffect(.degrees(Double((index * 17) % 26) - 13))
        .position(x: size.width * (0.04 + CGFloat(index) / 25 * 0.92), y: size.height * (0.82 + CGFloat(index % 4) * 0.035))
    }

    private func grainKernel(grain: Int, height: CGFloat) -> some View {
        let color = config.accentColors[(grain + 1) % config.accentColors.count].opacity(0.62)
        let direction: CGFloat = grain % 2 == 0 ? -1 : 1
        let x = direction * height * 0.08
        let y = -height * (0.18 + CGFloat(grain) * 0.10)
        let rotation = Double(grain % 2 == 0 ? -32 : 32)

        return Capsule()
            .fill(color)
            .frame(width: height * 0.12, height: height * 0.035)
            .offset(x: x, y: y)
            .rotationEffect(.degrees(rotation))
    }

    private func beachUmbrella(index: Int, in size: CGSize) -> some View {
        let umbrellaSize = size.shortSide * (0.10 + CGFloat(index % 2) * 0.025)
        let x = size.width * (0.16 + CGFloat(index) * 0.30)
        let y = size.height * (index % 2 == 0 ? 0.82 : 0.90)
        return ZStack {
            Rectangle()
                .fill(config.accentColors[1].opacity(0.58))
                .frame(width: max(umbrellaSize * 0.05, 3), height: umbrellaSize * 0.72)
                .offset(y: umbrellaSize * 0.24)
            HalfCircleShape()
                .fill(config.accentColors[index % config.accentColors.count].opacity(0.80))
                .frame(width: umbrellaSize, height: umbrellaSize * 0.46)
        }
        .rotationEffect(.degrees(Double(index % 2 == 0 ? -7 : 8)))
        .position(x: x, y: y)
    }

    private func christmasTree(index: Int, in size: CGSize) -> some View {
        let treeSize = size.shortSide * (0.13 + CGFloat(index % 2) * 0.035)
        let x = size.width * (0.10 + CGFloat(index) * 0.25)
        let y = size.height * (index % 2 == 0 ? 0.82 : 0.90)
        return ZStack {
            Rectangle()
                .fill(Color(red: 0.35, green: 0.18, blue: 0.08).opacity(0.66))
                .frame(width: treeSize * 0.13, height: treeSize * 0.28)
                .offset(y: treeSize * 0.34)
            ForEach(0..<3, id: \.self) { layer in
                TriangleShape()
                    .fill(config.accentColors[2].opacity(0.70 + Double(layer) * 0.06))
                    .frame(width: treeSize * (1 - CGFloat(layer) * 0.18), height: treeSize * 0.52)
                    .offset(y: -treeSize * CGFloat(layer) * 0.18)
            }
        }
        .position(x: x, y: y)
    }

    private func bottomDrift(size: CGSize, color: Color, height: CGFloat, yOffset: CGFloat) -> some View {
        WaveShape(phase: 0.18)
            .fill(color)
            .frame(width: size.width * 1.12, height: size.height * height)
            .position(x: size.width * 0.5, y: size.height * (1 - height / 2 + yOffset))
    }

    private func summerWave(index: Int, in size: CGSize) -> some View {
        let color = config.accentColors[(index + 1) % config.accentColors.count].opacity(0.24)
        let height = size.height * (0.12 + CGFloat(index) * 0.015)
        let y = size.height * (0.76 + CGFloat(index) * 0.055)

        return WaveShape(phase: CGFloat(index) * 0.32)
            .fill(color)
            .frame(width: size.width * 1.14, height: height)
            .position(x: size.width * 0.5, y: y)
    }

    private func decorativeOrb(size: CGSize, color: Color, x: CGFloat, y: CGFloat, diameter: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: size.shortSide * diameter, height: size.shortSide * diameter)
            .position(x: size.width * x, y: size.height * y)
            .blur(radius: size.shortSide * 0.018)
    }

    private func edgePoint(index: Int, in size: CGSize, topBias: CGFloat) -> CGPoint {
        let xSeed = CGFloat((index * 37) % 100) / 100
        let ySeed = CGFloat((index * 53) % 100) / 100
        let x = index % 5 == 0 ? CGFloat(index % 2 == 0 ? 0.06 : 0.94) : xSeed
        let y = ySeed < topBias ? ySeed * 0.34 : 0.68 + ySeed * 0.30
        return CGPoint(x: size.width * x, y: size.height * y)
    }

    private func bottomSidePoint(index: Int, in size: CGSize) -> CGPoint {
        let sideOffset = CGFloat((index * 29) % 100) / 100
        let x = index % 4 == 0 ? 0.07 + sideOffset * 0.08 : index % 4 == 1 ? 0.85 + sideOffset * 0.10 : 0.12 + sideOffset * 0.76
        let y = 0.76 + CGFloat((index * 41) % 100) / 100 * 0.20
        return CGPoint(x: size.width * x, y: size.height * y)
    }

    private func autumnPoint(index: Int, in size: CGSize) -> CGPoint {
        let xSeed = CGFloat((index * 43) % 100) / 100
        let ySeed = CGFloat((index * 61) % 100) / 100
        let x = index % 3 == 0 ? 0.05 + xSeed * 0.12 : index % 3 == 1 ? 0.82 + xSeed * 0.12 : xSeed
        let y = index % 4 == 0 ? 0.10 + ySeed * 0.12 : 0.70 + ySeed * 0.26
        return CGPoint(x: size.width * x, y: size.height * y)
    }

    private func sideX(_ index: Int) -> CGFloat {
        index % 2 == 0 ? 0.07 + CGFloat((index * 17) % 10) / 180 : 0.90 + CGFloat((index * 19) % 10) / 180
    }

    private func snowSize(_ index: Int) -> CGFloat {
        CGFloat(6 + (index * 7) % 14)
    }

    private func flowerSize(_ index: Int) -> CGFloat {
        CGFloat(30 + (index * 11) % 34)
    }

    private func leafSize(_ index: Int) -> CGFloat {
        CGFloat(28 + (index * 13) % 36)
    }

    private func lightSize(_ index: Int) -> CGFloat {
        CGFloat(12 + (index * 5) % 14)
    }

    private func confettiWidth(_ index: Int) -> CGFloat {
        CGFloat(7 + (index * 7) % 12)
    }

    private func confettiHeight(_ index: Int) -> CGFloat {
        CGFloat(18 + (index * 11) % 24)
    }

    private func eggSize(_ index: Int) -> CGFloat {
        CGFloat(54 + (index * 13) % 34)
    }

    private func starSize(_ index: Int) -> CGFloat {
        CGFloat(12 + (index * 7) % 18)
    }

    private func colorCloudSize(_ index: Int) -> CGFloat {
        CGFloat(70 + (index * 29) % 110)
    }

    private func batWidth(_ index: Int) -> CGFloat {
        CGFloat(32 + (index * 11) % 38)
    }
}

private struct SeasonalBackgroundConfig {
    enum Kind {
        case winter
        case spring
        case summer
        case autumn
        case rain
        case festive
        case frost
        case meadow
        case beach
        case harvest
        case fireworks
        case confetti
        case easter
        case crescent
        case lanterns
        case candles
        case colorClouds
        case diyas
        case midsummer
        case halloween
        case christmasTrees
    }

    let kind: Kind
    let baseColors: [Color]
    let accentColors: [Color]
    let centerDimming: Double

    static func occasion(kind: Kind, baseColors: [Color], accentColors: [Color]) -> SeasonalBackgroundConfig {
        SeasonalBackgroundConfig(
            kind: kind,
            baseColors: baseColors,
            accentColors: accentColors,
            centerDimming: 0.30
        )
    }

    static func config(for month: Int) -> SeasonalBackgroundConfig {
        switch month {
        case 1:
            return SeasonalBackgroundConfig(
                kind: .frost,
                baseColors: [Color(red: 0.02, green: 0.08, blue: 0.17), Color(red: 0.08, green: 0.20, blue: 0.32), Color(red: 0.62, green: 0.78, blue: 0.88)],
                accentColors: [Color(red: 0.72, green: 0.92, blue: 1.00), Color(red: 0.92, green: 0.98, blue: 1.00), Color(red: 0.42, green: 0.66, blue: 0.90)],
                centerDimming: 0.24
            )
        case 2:
            return SeasonalBackgroundConfig(
                kind: .winter,
                baseColors: [Color(red: 0.18, green: 0.06, blue: 0.18), Color(red: 0.34, green: 0.12, blue: 0.28), Color(red: 0.76, green: 0.42, blue: 0.62)],
                accentColors: [Color(red: 1.00, green: 0.66, blue: 0.82), Color(red: 0.96, green: 0.88, blue: 0.96), Color(red: 0.66, green: 0.36, blue: 0.72)],
                centerDimming: 0.24
            )
        case 3:
            return SeasonalBackgroundConfig(
                kind: .rain,
                baseColors: [Color(red: 0.08, green: 0.16, blue: 0.20), Color(red: 0.15, green: 0.28, blue: 0.29), Color(red: 0.38, green: 0.56, blue: 0.44)],
                accentColors: [Color(red: 0.61, green: 0.82, blue: 0.74), Color(red: 0.55, green: 0.72, blue: 0.90), Color(red: 0.76, green: 0.88, blue: 0.65)],
                centerDimming: 0.24
            )
        case 4:
            return SeasonalBackgroundConfig(
                kind: .spring,
                baseColors: [Color(red: 0.08, green: 0.18, blue: 0.24), Color(red: 0.16, green: 0.32, blue: 0.34), Color(red: 0.58, green: 0.52, blue: 0.78)],
                accentColors: [Color(red: 0.98, green: 0.82, blue: 0.40), Color(red: 0.52, green: 0.82, blue: 0.74), Color(red: 0.86, green: 0.54, blue: 0.82), Color(red: 0.64, green: 0.70, blue: 1.00)],
                centerDimming: 0.25
            )
        case 5:
            return SeasonalBackgroundConfig(
                kind: .meadow,
                baseColors: [Color(red: 0.04, green: 0.22, blue: 0.14), Color(red: 0.12, green: 0.44, blue: 0.24), Color(red: 0.82, green: 0.68, blue: 0.30)],
                accentColors: [Color(red: 1.00, green: 0.78, blue: 0.24), Color(red: 0.42, green: 0.78, blue: 0.26), Color(red: 0.96, green: 0.36, blue: 0.52), Color(red: 1.00, green: 0.88, blue: 0.92)],
                centerDimming: 0.25
            )
        case 6:
            return SeasonalBackgroundConfig(
                kind: .midsummer,
                baseColors: [Color(red: 0.04, green: 0.22, blue: 0.24), Color(red: 0.14, green: 0.40, blue: 0.32), Color(red: 0.92, green: 0.66, blue: 0.34)],
                accentColors: [Color(red: 1.00, green: 0.84, blue: 0.28), Color(red: 0.48, green: 0.82, blue: 0.34), Color(red: 0.96, green: 0.54, blue: 0.72)],
                centerDimming: 0.26
            )
        case 7:
            return SeasonalBackgroundConfig(
                kind: .summer,
                baseColors: [Color(red: 0.02, green: 0.20, blue: 0.36), Color(red: 0.04, green: 0.46, blue: 0.62), Color(red: 0.96, green: 0.66, blue: 0.34)],
                accentColors: [Color(red: 1.00, green: 0.84, blue: 0.28), Color(red: 0.20, green: 0.70, blue: 0.92), Color(red: 0.48, green: 0.88, blue: 0.88), Color(red: 0.94, green: 0.76, blue: 0.48)],
                centerDimming: 0.27
            )
        case 8:
            return SeasonalBackgroundConfig(
                kind: .beach,
                baseColors: [Color(red: 0.02, green: 0.28, blue: 0.46), Color(red: 0.04, green: 0.58, blue: 0.72), Color(red: 0.98, green: 0.72, blue: 0.40)],
                accentColors: [Color(red: 1.00, green: 0.86, blue: 0.30), Color(red: 0.10, green: 0.62, blue: 0.82), Color(red: 0.52, green: 0.90, blue: 0.92), Color(red: 0.96, green: 0.78, blue: 0.48)],
                centerDimming: 0.28
            )
        case 9:
            return SeasonalBackgroundConfig(
                kind: .harvest,
                baseColors: [Color(red: 0.10, green: 0.18, blue: 0.14), Color(red: 0.30, green: 0.34, blue: 0.18), Color(red: 0.88, green: 0.62, blue: 0.26)],
                accentColors: [Color(red: 0.98, green: 0.74, blue: 0.24), Color(red: 0.66, green: 0.54, blue: 0.22), Color(red: 0.44, green: 0.58, blue: 0.24), Color(red: 0.86, green: 0.50, blue: 0.18)],
                centerDimming: 0.27
            )
        case 10:
            return SeasonalBackgroundConfig(
                kind: .autumn,
                baseColors: [Color(red: 0.12, green: 0.08, blue: 0.10), Color(red: 0.32, green: 0.16, blue: 0.14), Color(red: 0.82, green: 0.38, blue: 0.14)],
                accentColors: [Color(red: 0.94, green: 0.46, blue: 0.12), Color(red: 0.72, green: 0.20, blue: 0.12), Color(red: 0.96, green: 0.68, blue: 0.20), Color(red: 0.46, green: 0.22, blue: 0.12)],
                centerDimming: 0.28
            )
        case 11:
            return SeasonalBackgroundConfig(
                kind: .rain,
                baseColors: [Color(red: 0.06, green: 0.08, blue: 0.11), Color(red: 0.18, green: 0.20, blue: 0.24), Color(red: 0.42, green: 0.36, blue: 0.30)],
                accentColors: [Color(red: 0.52, green: 0.62, blue: 0.68), Color(red: 0.74, green: 0.62, blue: 0.46), Color(red: 0.34, green: 0.42, blue: 0.48)],
                centerDimming: 0.30
            )
        default:
            return SeasonalBackgroundConfig(
                kind: .festive,
                baseColors: [Color(red: 0.04, green: 0.10, blue: 0.13), Color(red: 0.08, green: 0.22, blue: 0.18), Color(red: 0.42, green: 0.10, blue: 0.12)],
                accentColors: [Color(red: 0.96, green: 0.82, blue: 0.36), Color(red: 0.88, green: 0.20, blue: 0.18), Color(red: 0.24, green: 0.66, blue: 0.46), Color(red: 0.86, green: 0.94, blue: 1.00)],
                centerDimming: 0.28
            )
        }
    }
}

private struct WaveShape: Shape {
    let phase: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))

        let step = max(rect.width / 5, 1)
        for index in 0...5 {
            let x = rect.minX + CGFloat(index) * step
            let y = rect.midY + sin(CGFloat(index) * .pi * 0.82 + phase * .pi * 2) * rect.height * 0.18
            path.addLine(to: CGPoint(x: x, y: y))
        }

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct LeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.22),
            control2: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.78)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.78),
            control2: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.22)
        )
        return path
    }
}

private struct MountainShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.30, y: rect.minY + rect.height * 0.34))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.48, y: rect.minY + rect.height * 0.58))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.68, y: rect.minY + rect.height * 0.18))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct HalfCircleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct EggShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control1: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.06),
            control2: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.30)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.82),
            control2: CGPoint(x: rect.midX + rect.width * 0.25, y: rect.maxY)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.midY),
            control1: CGPoint(x: rect.midX - rect.width * 0.25, y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.82)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.30),
            control2: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.06)
        )
        return path
    }
}

private struct CrescentShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: rect)
        path.addEllipse(in: rect.offsetBy(dx: rect.width * 0.28, dy: -rect.height * 0.06).insetBy(dx: rect.width * 0.06, dy: rect.height * 0.04))
        return path
    }
}

private struct StarShape: Shape {
    let points: Int

    func path(in rect: CGRect) -> Path {
        let pointCount = max(points, 4)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2
        let innerRadius = outerRadius * 0.42
        var path = Path()

        for index in 0..<(pointCount * 2) {
            let radius = index.isMultiple(of: 2) ? outerRadius : innerRadius
            let angle = CGFloat(index) * .pi / CGFloat(pointCount) - .pi / 2
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        path.closeSubpath()
        return path
    }
}

private struct FlameShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.38),
            control2: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.38)
        )
        return path
    }
}

private struct DiyaShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.minY))
        return path
    }
}

private extension CGSize {
    var shortSide: CGFloat {
        min(width, height)
    }
}

private struct TopPodcastSharePreviewTile: View {
    let design: TopPodcastShareDesign
    let image: UIImage?
    let aspectRatio: CGFloat
    let isSelected: Bool
    let isRendering: Bool
    let selectAction: () -> Void
    let shareAction: () -> Void

    private var accessibilityLabelText: String {
        isSelected ? "Deselect \(design.title)" : "Select \(design.title)"
    }

    private func shareIfImageIsReady() {
        guard image != nil else { return }
        shareAction()
    }

    private var previewContent: some View {
        return ZStack {
            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))

                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView()
                            .controlSize(.regular)
                    }
                }
                .aspectRatio(aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(isRendering && image == nil ? 0.72 : 1)
            }
        }
    }

    private var selectionStrokeColor: Color {
        isSelected ? Color.accentColor : Color.secondary.opacity(0.18)
    }

    private var selectionStrokeWidth: CGFloat {
        isSelected ? 3 : 1
    }

    private var tileBackgroundColor: Color {
        isSelected ? Color.accentColor.opacity(0.15) : Color(uiColor: .tertiarySystemGroupedBackground)
    }

    var body: some View {
        previewContent
        .padding(8)
        .background(
            tileBackgroundColor,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selectionStrokeColor, lineWidth: selectionStrokeWidth)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(perform: selectAction)
        .onLongPressGesture(minimumDuration: 0.45, perform: shareIfImageIsReady)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            selectAction()
        }
    }
}

func topPodcastShareItems(from rollups: [PodcastRollup]) async -> [TopPodcastShareItem] {
    var items: [TopPodcastShareItem] = []
    items.reserveCapacity(rollups.count)

    for (index, rollup) in rollups.enumerated() {
        let coverImage: UIImage?
        if let coverURL = rollup.coverURL {
            coverImage = await ImageLoaderAndCache.loadUIImage(from: coverURL)
        } else {
            coverImage = nil
        }

        items.append(
            TopPodcastShareItem(
                rank: index + 1,
                podcastName: rollup.podcastName,
                totalSeconds: rollup.totalSeconds,
                coverImage: coverImage
            )
        )
    }

    return items
}

@MainActor
func renderTopPodcastShareImage(
    items: [TopPodcastShareItem],
    design: TopPodcastShareDesign,
    periodLabel: String,
    dateRangeLabel: String,
    totalListeningSeconds: Double,
    shareTitle: String,
    background: TopPodcastShareBackground,
    renderSize: CGSize,
    stats: TopPodcastShareStats,
    durationFormatter: @escaping (Double) -> String
) -> UIImage? {
    let renderer = ImageRenderer(
        content: TopPodcastShareCard(
            items: items,
            design: design,
            periodLabel: periodLabel,
            dateRangeLabel: dateRangeLabel,
            totalListeningSeconds: totalListeningSeconds,
            shareTitle: shareTitle,
            background: background,
            renderSize: renderSize,
            stats: stats,
            durationFormatter: durationFormatter
        )
        .frame(width: renderSize.width, height: renderSize.height)
    )
    renderer.scale = 1
    return renderer.uiImage
}

private struct TopPodcastShareCard: View {
    let items: [TopPodcastShareItem]
    let design: TopPodcastShareDesign
    let periodLabel: String
    let dateRangeLabel: String
    let totalListeningSeconds: Double
    let shareTitle: String
    let background: TopPodcastShareBackground
    let renderSize: CGSize
    let stats: TopPodcastShareStats
    let durationFormatter: (Double) -> String

    var body: some View {
        Group {
            switch design {
            case .podium:
                podiumCard
            case .billboard:
                billboardCard
            case .coverGrid:
                coverGridCard
            case .coverCollage:
                coverCollageCard
            case .coverCloud:
                coverCloudCard
            case .horizontalBars:
                horizontalBarsCard
            case .pieChart:
                pieChartCard
            case .statistics:
                statisticsCard
            }
        }
        .foregroundStyle(primaryTextColor)
    }

    private var primaryTextColor: Color {
        background.isLight ? .black : .white
    }

    private var secondaryTextColor: Color {
        primaryTextColor.opacity(background.isLight ? 0.66 : 0.76)
    }

    private var tertiaryTextColor: Color {
        primaryTextColor.opacity(background.isLight ? 0.58 : 0.65)
    }

    private var artworkShadowColor: Color {
        background.isLight ? .black.opacity(0.18) : .black.opacity(0.34)
    }

    private var isLandscape: Bool {
        renderSize.width > renderSize.height
    }

    private var isSquare: Bool {
        abs(renderSize.width - renderSize.height) < 1
    }

    private var layoutScale: CGFloat {
        if isLandscape {
            return 0.64
        }
        if isSquare {
            return 0.76
        }
        return 1
    }

    private func scaled(_ value: CGFloat, minimum: CGFloat = 0) -> CGFloat {
        max(value * layoutScale, minimum)
    }

    private func cardPadding(_ value: CGFloat) -> CGFloat {
        max(value * layoutScale, isLandscape ? 34 : 42)
    }

    private var gridColumnCount: Int {
        if isLandscape {
            return 6
        }
        if isSquare {
            return 4
        }
        return 3
    }

    private var gridItemCount: Int {
        if isLandscape {
            return min(items.count, 12)
        }
        if isSquare {
            return min(items.count, 12)
        }
        return min(items.count, 12)
    }

    @ViewBuilder
    private func shareBackground<CurrentBackground: View>(
        @ViewBuilder current: () -> CurrentBackground
    ) -> some View {
        if let occasionConfig = background.occasionConfig {
            SeasonalPodcastShareBackground(config: occasionConfig)
        } else if let month = background.seasonalMonth {
            SeasonalPodcastShareBackground(month: month)
        } else {
            switch background {
            case .current:
                current()
            case .stripes:
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        ForEach(Array(TopPodcastShareBackground.stripeColors.enumerated()), id: \.offset) { _, color in
                            color
                                .frame(height: geometry.size.height / CGFloat(TopPodcastShareBackground.stripeColors.count))
                        }
                    }
                }
            case .rainbowGradient:
                LinearGradient(
                    colors: TopPodcastShareBackground.stripeColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .white:
                Color.white
            case .black:
                Color.black
            default:
                current()
            }
        }
    }

    private var podiumCard: some View {
        let podiumItems = [items[safe: 1], items[safe: 0], items[safe: 2]].compactMap(\.self)

        return ZStack {
            shareBackground {
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.09, blue: 0.15),
                        Color(red: 0.04, green: 0.18, blue: 0.22),
                        Color(red: 0.47, green: 0.17, blue: 0.12)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            VStack(alignment: .leading, spacing: scaled(34, minimum: 18)) {
                shareHeader(title: shareTitle, subtitle: periodLabel)

                HStack(alignment: .bottom, spacing: scaled(28, minimum: 14)) {
                    ForEach(podiumItems) { item in
                        PodiumPodcastColumn(
                            item: item,
                            height: scaled(podiumHeight(for: item.rank), minimum: 120),
                            duration: durationFormatter(item.totalSeconds),
                            durationColor: secondaryTextColor,
                            podiumFillColor: primaryTextColor.opacity(item.rank == 1 ? 0.30 : 0.20),
                            podiumStrokeColor: primaryTextColor.opacity(0.18),
                            artworkShadowColor: artworkShadowColor,
                            scale: layoutScale
                        )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: scaled(790, minimum: 300), alignment: .bottom)

                Spacer(minLength: 0)
                footer
            }
            .padding(cardPadding(70))
        }
    }

    private var billboardCard: some View {
        let rowScale: CGFloat = isLandscape ? 0.54 : (isSquare ? 0.64 : 1)
        let rowSpacing: CGFloat = isLandscape ? 6 : (isSquare ? 7 : 14)

        return ZStack {
            shareBackground {
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.06, blue: 0.07),
                        Color(red: 0.16, green: 0.12, blue: 0.09),
                        Color(red: 0.64, green: 0.18, blue: 0.12)
                    ],
                    startPoint: .top,
                    endPoint: .bottomTrailing
                )
            }

            VStack(alignment: .leading, spacing: scaled(28, minimum: 12)) {
                shareHeader(title: shareTitle, subtitle: periodLabel)

                VStack(spacing: rowSpacing) {
                    ForEach(items.prefix(10)) { item in
                        BillboardPodcastRow(
                            item: item,
                            duration: durationFormatter(item.totalSeconds),
                            durationColor: secondaryTextColor,
                            rowBackgroundColor: primaryTextColor.opacity(item.rank == 1 ? 0.20 : 0.12),
                            scale: rowScale
                        )
                    }
                }

                Spacer(minLength: 0)
                footer
            }
            .padding(cardPadding(58))
        }
    }

    private var coverGridCard: some View {
        let gridItems = Array(items.prefix(gridItemCount))

        return ZStack {
            shareBackground {
                LinearGradient(
                    colors: [
                        Color(red: 0.03, green: 0.08, blue: 0.10),
                        Color(red: 0.08, green: 0.20, blue: 0.18),
                        Color(red: 0.56, green: 0.32, blue: 0.15)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            VStack(alignment: .leading, spacing: scaled(36, minimum: 18)) {
                shareHeader(title: shareTitle, subtitle: periodLabel)

                CoverGridLayout(
                    items: gridItems,
                    columns: gridColumnCount,
                    spacing: scaled(22, minimum: 10),
                    shadowColor: artworkShadowColor
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Spacer(minLength: 0)

                footer
            }
            .padding(cardPadding(64))
        }
    }

    private var coverCollageCard: some View {
        return ZStack {
            shareBackground {
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.07, blue: 0.10),
                        Color(red: 0.12, green: 0.17, blue: 0.23),
                        Color(red: 0.46, green: 0.22, blue: 0.34)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            VStack(alignment: .leading, spacing: scaled(26, minimum: 12)) {
                shareHeader(title: shareTitle, subtitle: periodLabel)

                if isLandscape {
                    landscapeCoverCollageContent
                } else if isSquare {
                    squareCoverCollageContent
                } else {
                    portraitCoverCollageContent
                }

                Spacer(minLength: 0)
                footer
            }
            .padding(cardPadding(60))
        }
    }

    private var portraitCoverCollageContent: some View {
        let heroItem = items.first
        let secondRow = Array(items.dropFirst().prefix(2))
        let thirdRow = Array(items.dropFirst(3).prefix(3))
        let bottomRow = Array(items.dropFirst(6).prefix(4))

        return VStack(spacing: scaled(26, minimum: 12)) {
            if let heroItem {
                PodcastShareArtwork(image: heroItem.coverImage, size: scaled(500, minimum: 260))
                    .shadow(color: artworkShadowColor, radius: 18, y: 14)
                    .frame(maxWidth: .infinity)
            }

            coverCollageRow(secondRow, size: scaled(260, minimum: 120), spacing: scaled(26, minimum: 10))
            coverCollageRow(thirdRow, size: scaled(190, minimum: 92), spacing: scaled(20, minimum: 8))

            if !bottomRow.isEmpty {
                coverCollageRow(bottomRow, size: scaled(145, minimum: 68), spacing: scaled(16, minimum: 7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var squareCoverCollageContent: some View {
        let topItems = Array(items.prefix(2))
        let middleItems = Array(items.dropFirst(2).prefix(3))
        let bottomItems = Array(items.dropFirst(5).prefix(4))

        return VStack(spacing: scaled(22, minimum: 10)) {
            coverCollageRow(topItems, size: scaled(300, minimum: 150), spacing: scaled(28, minimum: 12))
            coverCollageRow(middleItems, size: scaled(205, minimum: 104), spacing: scaled(22, minimum: 9))
            coverCollageRow(bottomItems, size: scaled(150, minimum: 76), spacing: scaled(16, minimum: 7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var landscapeCoverCollageContent: some View {
        CoverCollageLandscapeLayout(items: Array(items.prefix(12)), shadowColor: artworkShadowColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func coverCollageRow(_ rowItems: [TopPodcastShareItem], size: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(rowItems) { item in
                PodcastShareArtwork(image: item.coverImage, size: size)
                    .shadow(color: artworkShadowColor, radius: 14, y: 10)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var coverCloudCard: some View {
        ZStack {
            shareBackground {
                LinearGradient(
                    colors: [
                        Color(red: 0.03, green: 0.07, blue: 0.10),
                        Color(red: 0.10, green: 0.15, blue: 0.21),
                        Color(red: 0.42, green: 0.18, blue: 0.30)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            VStack(alignment: .leading, spacing: scaled(26, minimum: 14)) {
                shareHeader(title: shareTitle, subtitle: periodLabel)

                CoverCloudLayout(items: items, shadowColor: artworkShadowColor)
                    .frame(maxWidth: .infinity, minHeight: scaled(800, minimum: 300))

                Spacer(minLength: 0)
                footer
            }
            .padding(cardPadding(60))
        }
    }

    private var statisticsCard: some View {
        ZStack {
            shareBackground {
                LinearGradient(
                    colors: [
                        Color(red: 0.02, green: 0.13, blue: 0.11),
                        Color(red: 0.04, green: 0.22, blue: 0.18),
                        Color(red: 0.01, green: 0.08, blue: 0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            VStack(alignment: .leading, spacing: scaled(28, minimum: 12)) {
                shareHeader(title: shareTitle, subtitle: periodLabel)

                statisticsContent

                Spacer(minLength: 0)

                footer
            }
            .padding(cardPadding(64))
        }
    }

    @ViewBuilder
    private var statisticsContent: some View {
        if isLandscape {
            HStack(alignment: .center, spacing: 34) {
                statisticsHero
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                LazyVGrid(columns: statisticsGridColumns, alignment: .leading, spacing: 18) {
                    wrappedStat(label: "Top Podcast", value: stats.topPodcastName)
                    wrappedStat(label: "Top Podcast Time", value: stats.topPodcastListeningTime)
                    wrappedStat(label: "Podcasts", value: formattedCount(stats.podcastCount))
                    wrappedStat(label: "Sessions", value: formattedCount(stats.listeningSessionCount))
                    wrappedStat(label: "Busiest Day", value: stats.busiestDayLabel)
                    wrappedStat(label: "Busiest Hour", value: stats.busiestHourLabel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: scaled(24, minimum: 10)) {
                statisticsHero

                LazyVGrid(columns: statisticsGridColumns, alignment: .leading, spacing: scaled(18, minimum: 8)) {
                    wrappedStat(label: "Top Podcast", value: stats.topPodcastName)
                    wrappedStat(label: "Top Podcast Time", value: stats.topPodcastListeningTime)
                    wrappedStat(label: "Podcasts", value: formattedCount(stats.podcastCount))
                    wrappedStat(label: "Sessions", value: formattedCount(stats.listeningSessionCount))
                    wrappedStat(label: "Busiest Day", value: stats.busiestDayLabel)
                    wrappedStat(label: "Busiest Hour", value: stats.busiestHourLabel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var statisticsHero: some View {
        VStack(alignment: .leading, spacing: scaled(8, minimum: 4)) {
            Text(stats.totalListeningTime)
                .font(.system(size: statisticsHeroFontSize, weight: .black, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .monospacedDigit()
            Text("total listening time")
                .font(.system(size: isLandscape ? 30 : scaled(28, minimum: 18), weight: .bold, design: .rounded))
                .foregroundStyle(secondaryTextColor)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var horizontalBarsCard: some View {
        let chartItems = Array(items.prefix(horizontalBarItemLimit))
        let chartTotalSeconds = max(totalListeningSeconds, chartItems.reduce(0) { $0 + $1.totalSeconds }, 1)

        return ZStack {
            shareBackground {
                LinearGradient(
                    colors: [
                        Color(red: 0.03, green: 0.08, blue: 0.11),
                        Color(red: 0.07, green: 0.20, blue: 0.22),
                        Color(red: 0.35, green: 0.18, blue: 0.30)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            VStack(alignment: .leading, spacing: scaled(34, minimum: 16)) {
                shareHeader(title: shareTitle, subtitle: periodLabel)

                VStack(spacing: scaled(18, minimum: 8)) {
                    ForEach(chartItems) { item in
                        PodcastShareBarRow(
                            item: item,
                            duration: durationFormatter(item.totalSeconds),
                            totalSeconds: chartTotalSeconds,
                            textColor: primaryTextColor,
                            secondaryTextColor: secondaryTextColor,
                            trackColor: primaryTextColor.opacity(background.isLight ? 0.10 : 0.16),
                            barColor: primaryTextColor.opacity(background.isLight ? 0.68 : 0.72),
                            artworkShadowColor: artworkShadowColor,
                            scale: horizontalBarScale
                        )
                    }
                }

                Spacer(minLength: 0)
                footer
            }
            .padding(cardPadding(58))
        }
    }

    private var pieChartCard: some View {
        let chartItems = Array(items.prefix(10))

        return ZStack {
            shareBackground {
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.06, blue: 0.10),
                        Color(red: 0.12, green: 0.13, blue: 0.23),
                        Color(red: 0.45, green: 0.20, blue: 0.21)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            VStack(alignment: .leading, spacing: scaled(34, minimum: 16)) {
                shareHeader(title: shareTitle, subtitle: periodLabel)

                PodcastSharePieChart(
                    items: chartItems,
                    totalListeningSeconds: totalListeningSeconds,
                    durationFormatter: durationFormatter,
                    textColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    otherColor: primaryTextColor.opacity(background.isLight ? 0.16 : 0.24),
                    legendPlacement: isLandscape ? .trailing : .bottom,
                    scale: layoutScale
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Spacer(minLength: 0)
                footer
            }
            .padding(cardPadding(58))
        }
    }

    private func shareHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: scaled(12, minimum: 6)) {
            Text(title)
                .font(.system(size: scaled(78, minimum: 42), weight: .black, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.72)
            Text(subtitle)
                .font(.system(size: scaled(42, minimum: 24), weight: .bold, design: .rounded))
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private func wrappedStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: scaled(7, minimum: 3)) {
            Text(label)
                .font(.system(size: scaled(22, minimum: 14), weight: .medium, design: .rounded))
                .foregroundStyle(tertiaryTextColor)
            Text(value)
                .font(.system(size: scaled(34, minimum: 20), weight: .heavy, design: .rounded))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .minimumScaleFactor(0.66)
        }
        .padding(.horizontal, scaled(20, minimum: 10))
        .padding(.vertical, scaled(16, minimum: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(primaryTextColor.opacity(background.isLight ? 0.08 : 0.11))
        )
    }

    private var statisticsGridColumns: [GridItem] {
        let columnCount = isLandscape ? 2 : (isSquare ? 2 : 1)
        let spacing: CGFloat = isLandscape ? 18 : scaled(16, minimum: 8)
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }

    private var statisticsHeroFontSize: CGFloat {
        if isLandscape {
            return 112
        }
        return scaled(96, minimum: 44)
    }

    private var horizontalBarItemLimit: Int {
        if isSquare {
            return 7
        }
        if isLandscape {
            return 6
        }
        return 10
    }

    private var horizontalBarScale: CGFloat {
        if isSquare {
            return 0.54
        }
        if isLandscape {
            return 0.50
        }
        return layoutScale
    }

    private func formattedCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: scaled(8, minimum: 4)) {
            HStack {
                Text("Up Next")
                    .font(.system(size: scaled(30, minimum: 18), weight: .bold, design: .rounded))
                Spacer()
                Text(dateRangeLabel)
                    .font(.system(size: scaled(24, minimum: 15), weight: .medium, design: .rounded))
                    .foregroundStyle(tertiaryTextColor)
            }

            Text(totalListeningLine)
                .font(.system(size: scaled(24, minimum: 15), weight: .semibold, design: .rounded))
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private var totalListeningLine: String {
        let hours = max(totalListeningSeconds / 3600, 0)
        let formatter = NumberFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = hours < 10 ? 1 : 0

        let formattedHours = formatter.string(from: NSNumber(value: hours)) ?? String(format: "%.0f", hours)
        return "\(formattedHours) hours of total listening time in Up Next"
    }

    private func podiumHeight(for rank: Int) -> CGFloat {
        switch rank {
        case 1:
            return 360
        case 2:
            return 280
        default:
            return 220
        }
    }
}

private struct CoverCloudLayout: View {
    let items: [TopPodcastShareItem]
    let shadowColor: Color

    var body: some View {
        GeometryReader { geometry in
            let placements = placements(in: geometry.size)

            ZStack {
                ForEach(placements) { placement in
                    PodcastShareArtwork(image: placement.item.coverImage, size: placement.size)
                        .shadow(color: shadowColor, radius: 14, y: 10)
                        .rotationEffect(.degrees(placement.rotation))
                        .position(x: placement.center.x, y: placement.center.y)
                        .zIndex(placement.zIndex)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func placements(in canvas: CGSize) -> [CoverCloudPlacement] {
        guard canvas.width > 0, canvas.height > 0, !items.isEmpty else { return [] }

        let sortedItems = items.sorted { lhs, rhs in
            if lhs.totalSeconds == rhs.totalSeconds {
                return lhs.rank < rhs.rank
            }
            return lhs.totalSeconds > rhs.totalSeconds
        }
        let maxSeconds = max(sortedItems.map(\.totalSeconds).max() ?? 1, 1)
        let countScale = min(1, max(0.42, sqrt(22 / Double(sortedItems.count))))
        let maxCoverSize = min(canvas.width, canvas.height) * 0.28
        let minCoverSize = max(42, min(canvas.width, canvas.height) * 0.065)

        var occupiedRects: [CGRect] = []
        var result: [CoverCloudPlacement] = []

        for (index, item) in sortedItems.enumerated() {
            let listeningShare = max(item.totalSeconds / maxSeconds, 0.04)
            let scaledSize = (74 + CGFloat(sqrt(listeningShare)) * 210) * CGFloat(countScale)
            let coverSize = min(maxCoverSize, max(minCoverSize, scaledSize))
            let rect = bestRect(
                for: item,
                index: index,
                coverSize: coverSize,
                canvas: canvas,
                occupiedRects: occupiedRects
            )
            let rotation = (deterministicUnit(item.rank * 7901 + index * 177) - 0.5) * 12

            occupiedRects.append(rect.insetBy(dx: -5, dy: -5))
            result.append(
                CoverCloudPlacement(
                    item: item,
                    size: coverSize,
                    center: CGPoint(x: rect.midX, y: rect.midY),
                    rotation: Double(rotation),
                    zIndex: Double(sortedItems.count - index)
                )
            )
        }

        return result
    }

    private func bestRect(
        for item: TopPodcastShareItem,
        index: Int,
        coverSize: CGFloat,
        canvas: CGSize,
        occupiedRects: [CGRect]
    ) -> CGRect {
        let defaultRect = CGRect(
            x: max((canvas.width - coverSize) / 2, 0),
            y: max((canvas.height - coverSize) / 2, 0),
            width: coverSize,
            height: coverSize
        )
        guard canvas.width > coverSize, canvas.height > coverSize else { return defaultRect }

        var bestRect = defaultRect
        var bestScore = CGFloat.greatestFiniteMagnitude

        for attempt in 0..<140 {
            let xSeed = item.rank * 9_973 + index * 479 + attempt * 37
            let ySeed = item.rank * 7_919 + index * 683 + attempt * 53
            let centerX = coverSize / 2 + deterministicUnit(xSeed) * (canvas.width - coverSize)
            let centerY = coverSize / 2 + deterministicUnit(ySeed) * (canvas.height - coverSize)
            let candidate = CGRect(
                x: centerX - coverSize / 2,
                y: centerY - coverSize / 2,
                width: coverSize,
                height: coverSize
            )
            let overlap = occupiedRects.reduce(CGFloat.zero) { total, rect in
                total + overlapArea(candidate, rect)
            }
            let centerBias = hypot(
                (centerX - canvas.width / 2) / canvas.width,
                (centerY - canvas.height / 2) / canvas.height
            )
            let score = overlap * 4 + centerBias * coverSize * 0.06 + CGFloat(attempt) * 0.001

            if score < bestScore {
                bestScore = score
                bestRect = candidate
                if overlap == 0, attempt > 10 {
                    break
                }
            }
        }

        return bestRect
    }

    private func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private func deterministicUnit(_ seed: Int) -> CGFloat {
        let raw = sin(Double(seed) * 12.9898) * 43_758.5453
        return CGFloat(raw - floor(raw))
    }
}

private struct CoverCloudPlacement: Identifiable {
    let item: TopPodcastShareItem
    let size: CGFloat
    let center: CGPoint
    let rotation: Double
    let zIndex: Double

    var id: Int { item.id }
}

private struct CoverGridLayout: View {
    let items: [TopPodcastShareItem]
    let columns: Int
    let spacing: CGFloat
    let shadowColor: Color

    var body: some View {
        GeometryReader { geometry in
            let columnCount = max(columns, 1)
            let rowCount = max(Int(ceil(Double(items.count) / Double(columnCount))), 1)
            let availableWidth = max(geometry.size.width - CGFloat(columnCount - 1) * spacing, 1)
            let availableHeight = max(geometry.size.height - CGFloat(rowCount - 1) * spacing, 1)
            let coverSize = min(
                availableWidth / CGFloat(columnCount),
                availableHeight / CGFloat(rowCount)
            )
            let gridWidth = coverSize * CGFloat(columnCount) + spacing * CGFloat(columnCount - 1)
            let gridHeight = coverSize * CGFloat(rowCount) + spacing * CGFloat(rowCount - 1)

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(coverSize), spacing: spacing), count: columnCount),
                spacing: spacing
            ) {
                ForEach(items) { item in
                    PodcastShareArtwork(image: item.coverImage, size: coverSize)
                        .shadow(color: shadowColor, radius: 14, y: 10)
                }
            }
            .frame(width: gridWidth, height: gridHeight)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

private struct CoverCollageLandscapeLayout: View {
    let items: [TopPodcastShareItem]
    let shadowColor: Color

    var body: some View {
        GeometryReader { geometry in
            let canvas = geometry.size
            let featuredItems = Array(items.prefix(4))
            let lowerItems = Array(items.dropFirst(4).prefix(8))
            let featuredSpacing = max(canvas.width * 0.018, 18)
            let lowerSpacing = max(canvas.width * 0.012, 12)
            let rowSpacing = max(canvas.height * 0.055, 22)
            let featuredSize = rowCoverSize(
                itemCount: featuredItems.count,
                spacing: featuredSpacing,
                maxWidth: canvas.width,
                maxHeight: canvas.height * (lowerItems.isEmpty ? 0.82 : 0.56)
            )
            let lowerSize = rowCoverSize(
                itemCount: lowerItems.count,
                spacing: lowerSpacing,
                maxWidth: canvas.width,
                maxHeight: canvas.height * 0.32
            )

            VStack(spacing: rowSpacing) {
                artworkRow(featuredItems, size: featuredSize, spacing: featuredSpacing, shadowRadius: 18)

                if !lowerItems.isEmpty {
                    artworkRow(lowerItems, size: lowerSize, spacing: lowerSpacing, shadowRadius: 14)
                }
            }
            .frame(width: canvas.width, height: canvas.height)
        }
    }

    private func rowCoverSize(itemCount: Int, spacing: CGFloat, maxWidth: CGFloat, maxHeight: CGFloat) -> CGFloat {
        guard itemCount > 0 else { return 1 }
        let availableWidth = maxWidth - CGFloat(itemCount - 1) * spacing
        return max(1, min(availableWidth / CGFloat(itemCount), maxHeight))
    }

    private func artworkRow(_ rowItems: [TopPodcastShareItem], size: CGFloat, spacing: CGFloat, shadowRadius: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(rowItems) { item in
                PodcastShareArtwork(image: item.coverImage, size: size)
                    .shadow(color: shadowColor, radius: shadowRadius, y: shadowRadius * 0.72)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PodiumPodcastColumn: View {
    let item: TopPodcastShareItem
    let height: CGFloat
    let duration: String
    let durationColor: Color
    let podiumFillColor: Color
    let podiumStrokeColor: Color
    let artworkShadowColor: Color
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 20 * scale) {
            PodcastShareArtwork(image: item.coverImage, size: (item.rank == 1 ? 250 : 210) * scale)
                .shadow(color: artworkShadowColor, radius: 18, y: 16)

            VStack(spacing: 8 * scale) {
                Text(item.podcastName)
                    .font(.system(size: (item.rank == 1 ? 34 : 28) * scale, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.72)
                Text(duration)
                    .font(.system(size: 24 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(durationColor)
                    .monospacedDigit()
            }
            .frame(height: 120 * scale, alignment: .top)

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(podiumFillColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(podiumStrokeColor, lineWidth: 2)
                    )
                Text("#\(item.rank)")
                    .font(.system(size: 72 * scale, weight: .black, design: .rounded))
                    .padding(.top, 34 * scale)
            }
            .frame(height: height)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BillboardPodcastRow: View {
    let item: TopPodcastShareItem
    let duration: String
    let durationColor: Color
    let rowBackgroundColor: Color
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 22 * scale) {
            Text("\(item.rank)")
                .font(.system(size: 42 * scale, weight: .black, design: .rounded))
                .monospacedDigit()
                .frame(width: 62 * scale, alignment: .trailing)

            PodcastShareArtwork(image: item.coverImage, size: 82 * scale)

            VStack(alignment: .leading, spacing: 6 * scale) {
                Text(item.podcastName)
                    .font(.system(size: 30 * scale, weight: .bold, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.76)
                Text(duration)
                    .font(.system(size: 22 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(durationColor)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24 * scale)
        .padding(.vertical, 16 * scale)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackgroundColor)
        )
    }
}

private struct PodcastShareBarRow: View {
    let item: TopPodcastShareItem
    let duration: String
    let totalSeconds: Double
    let textColor: Color
    let secondaryTextColor: Color
    let trackColor: Color
    let barColor: Color
    let artworkShadowColor: Color
    let scale: CGFloat

    private var progress: CGFloat {
        CGFloat(min(max(item.totalSeconds / max(totalSeconds, 1), 0), 1))
    }

    var body: some View {
        HStack(spacing: 18 * scale) {
            PodcastShareArtwork(image: item.coverImage, size: 76 * scale)
                .shadow(color: artworkShadowColor, radius: 8, y: 5)

            VStack(alignment: .leading, spacing: 10 * scale) {
                HStack(alignment: .firstTextBaseline, spacing: 12 * scale) {
                    Text(item.podcastName)
                        .font(.system(size: 27 * scale, weight: .heavy, design: .rounded))
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Spacer(minLength: 0)

                    Text(duration)
                        .font(.system(size: 22 * scale, weight: .bold, design: .rounded))
                        .foregroundStyle(secondaryTextColor)
                        .monospacedDigit()
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(trackColor)

                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(barColor)
                            .frame(width: max(geometry.size.width * progress, 8))
                    }
                }
                .frame(height: max(28 * scale, 12))
            }
        }
        .padding(16 * scale)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(textColor.opacity(0.10))
        )
    }
}

private struct PodcastSharePieChart: View {
    enum LegendPlacement {
        case trailing
        case bottom
    }

    let items: [TopPodcastShareItem]
    let totalListeningSeconds: Double
    let durationFormatter: (Double) -> String
    let textColor: Color
    let secondaryTextColor: Color
    let otherColor: Color
    let legendPlacement: LegendPlacement
    let scale: CGFloat

    private var segments: [PodcastSharePieSegment] {
        let totalSeconds = max(totalListeningSeconds, items.reduce(0) { $0 + $1.totalSeconds }, 1)
        var startAngle = -90.0
        var result: [PodcastSharePieSegment] = []

        for item in items where item.totalSeconds > 0 {
            let sweep = max(item.totalSeconds / totalSeconds * 360, 0)
            guard sweep > 0 else { continue }
            result.append(
                PodcastSharePieSegment(
                    id: item.id,
                    item: item,
                    title: item.podcastName,
                    seconds: item.totalSeconds,
                    startAngle: startAngle,
                    endAngle: startAngle + sweep,
                    color: .clear
                )
            )
            startAngle += sweep
        }

        let displayedSeconds = items.reduce(0) { $0 + $1.totalSeconds }
        let otherSeconds = max(totalSeconds - displayedSeconds, 0)
        if otherSeconds > totalSeconds * 0.002 {
            result.append(
                PodcastSharePieSegment(
                    id: -1,
                    item: nil,
                    title: "Other",
                    seconds: otherSeconds,
                    startAngle: startAngle,
                    endAngle: 270,
                    color: otherColor
                )
            )
        }

        return result
    }

    var body: some View {
        GeometryReader { geometry in
            if legendPlacement == .trailing {
                let chartSize = min(geometry.size.height * 0.92, geometry.size.width * 0.40)
                let leadingInset = max(geometry.size.width * 0.12, 110 * scale)
                let trailingInset = max(geometry.size.width * 0.04, 30 * scale)

                HStack(spacing: 34 * scale) {
                    Spacer(minLength: leadingInset)
                    pie(size: chartSize)
                    legend
                    Spacer(minLength: trailingInset)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                let chartSize = min(geometry.size.height * 0.62, geometry.size.width * 0.88)

                VStack(spacing: 24 * scale) {
                    pie(size: chartSize)
                    legend
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    private func pie(size: CGFloat) -> some View {
        ZStack {
            ForEach(segments) { segment in
                PodcastSharePieSlice(segment: segment, size: size)
            }

            Circle()
                .stroke(textColor.opacity(0.24), lineWidth: 3)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.22), radius: 18, y: 12)
    }

    private var legend: some View {
        Group {
            if legendPlacement == .trailing {
                VStack(alignment: .leading, spacing: 15 * scale) {
                    legendRows(limit: 7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 18 * scale), count: 2),
                    alignment: .leading,
                    spacing: 12 * scale
                ) {
                    legendRows(limit: 6)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func legendRows(limit: Int) -> some View {
        ForEach(segments.prefix(limit)) { segment in
            PodcastSharePieLegendRow(
                segment: segment,
                duration: durationFormatter(segment.seconds),
                textColor: textColor,
                secondaryTextColor: secondaryTextColor,
                otherColor: otherColor,
                scale: scale
            )
        }

        if segments.count > limit {
            Text("+\(segments.count - limit) more")
                .font(.system(size: 22 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(secondaryTextColor)
        }
    }
}

private struct PodcastSharePieSegment: Identifiable {
    let id: Int
    let item: TopPodcastShareItem?
    let title: String
    let seconds: Double
    let startAngle: Double
    let endAngle: Double
    let color: Color
}

private struct PodcastSharePieSlice: View {
    let segment: PodcastSharePieSegment
    let size: CGFloat

    var body: some View {
        ZStack {
            if let image = segment.item?.coverImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(sliceShape)
            } else {
                sliceShape
                    .fill(segment.color)
            }

            sliceShape
                .stroke(.white.opacity(0.30), lineWidth: 3)
        }
        .frame(width: size, height: size)
    }

    private var sliceShape: PodcastSharePieSliceShape {
        PodcastSharePieSliceShape(startAngle: segment.startAngle, endAngle: segment.endAngle)
    }
}

private struct PodcastSharePieLegendRow: View {
    let segment: PodcastSharePieSegment
    let duration: String
    let textColor: Color
    let secondaryTextColor: Color
    let otherColor: Color
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 12 * scale) {
            ZStack {
                if let image = segment.item?.coverImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    otherColor
                }
            }
            .frame(width: 42 * scale, height: 42 * scale)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(segment.title)
                    .font(.system(size: 23 * scale, weight: .heavy, design: .rounded))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(duration)
                    .font(.system(size: 19 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(secondaryTextColor)
                    .monospacedDigit()
            }
        }
    }
}

private struct PodcastSharePieSliceShape: Shape {
    let startAngle: Double
    let endAngle: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(startAngle),
            endAngle: .degrees(endAngle),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

private struct PodcastShareArtwork: View {
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.95, green: 0.40, blue: 0.25),
                            Color(red: 0.12, green: 0.55, blue: 0.62)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "waveform")
                        .font(.system(size: size * 0.34, weight: .bold))
                        .foregroundStyle(.white.opacity(0.88))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 2)
        )
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview {
    NavigationStack {
        StatisticsView()
    }
}
