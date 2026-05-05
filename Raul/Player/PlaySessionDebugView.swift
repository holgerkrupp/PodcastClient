import SwiftUI
import SwiftData
import Charts
import UIKit

private struct ListeningOverviewPoint: Identifiable {
    let date: Date
    let totalSeconds: Double

    var id: Date { date }
}

private struct PodcastRollup: Identifiable {
    let podcastName: String
    let podcastFeed: URL?
    let coverURL: URL?
    let totalSeconds: Double

    var id: String { podcastFeed?.absoluteString ?? podcastName }
}

private struct TopPodcastShareItem: Identifiable {
    let rank: Int
    let podcastName: String
    let totalSeconds: Double
    let coverImage: UIImage?

    var id: Int { rank }
}

private enum TopPodcastShareDesign: CaseIterable, Identifiable {
    case podium
    case billboard

    var id: Self { self }

    var title: String {
        switch self {
        case .podium:
            return "Podium Top 3"
        case .billboard:
            return "Billboard Top 10"
        }
    }

    var systemImage: String {
        switch self {
        case .podium:
            return "trophy"
        case .billboard:
            return "list.number"
        }
    }

    var minimumItemCount: Int {
        switch self {
        case .podium:
            return 3
        case .billboard:
            return 1
        }
    }

    var itemLimit: Int {
        switch self {
        case .podium:
            return 3
        case .billboard:
            return 10
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

struct PlaySessionDebugView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Podcast.title) private var podcasts: [Podcast]

    @State private var selectedPeriod: PlaySessionSummaryPeriod = .day
    @State private var selectedPeriodStart = Calendar.current.startOfDay(for: Date())
    @State private var selectedPodcastFeedString: String? = nil
    @State private var snapshot = ListeningHistorySnapshot.empty
    @State private var isRebuildingAnalytics = false
    @State private var rebuildStatusMessage: String?
    @State private var isPreparingPodcastShare = false
    @State private var showPodcastShareSheet = false
    @State private var podcastShareImage: UIImage?

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

                HStack(spacing: 10) {
                    Button {
                        rebuildAnalytics()
                    } label: {
                        Label(
                            isRebuildingAnalytics ? "Rebuilding…" : "Rebuild Analytics",
                            systemImage: "arrow.clockwise.circle"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRebuildingAnalytics)

                    if isRebuildingAnalytics {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer(minLength: 0)
                }

                if let rebuildStatusMessage {
                    Text(rebuildStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                        .foregroundStyle(.accent.opacity(0.18))

                        LineMark(
                            x: .value("Period", point.date),
                            y: .value("Listening", point.totalSeconds)
                        )
                        .foregroundStyle(.accent)
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
                        Spacer()
                        Menu {
                            Button {
                                shareTopPodcasts(as: .podium)
                            } label: {
                                Label(TopPodcastShareDesign.podium.title, systemImage: TopPodcastShareDesign.podium.systemImage)
                            }
                            .disabled(snapshot.podcastBreakdown.count < 3 || isPreparingPodcastShare)

                            Button {
                                shareTopPodcasts(as: .billboard)
                            } label: {
                                Label(TopPodcastShareDesign.billboard.title, systemImage: TopPodcastShareDesign.billboard.systemImage)
                            }
                            .disabled(isPreparingPodcastShare)
                        } label: {
                            if isPreparingPodcastShare {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .accessibilityLabel("Share top podcasts")
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
                    ForEach(snapshot.selectedPeriodSessions) { session in
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
                                Text(formatDuration(session.listenedSeconds))
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
                                Text("From \(formatTimestamp(startPosition)) to \(formatTimestamp(endPosition))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if !snapshot.groupedTotals.isEmpty {
                Section("Recent \(selectedPeriod.title)") {
                    ForEach(snapshot.groupedTotals.prefix(24)) { item in
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
                        }
                    }
                }
            }

            Section("More Views") {
                NavigationLink {
                    TopPodcastShareGalleryView(
                        rollups: snapshot.podcastBreakdown,
                        periodLabel: selectedPeriodLabel,
                        dateRangeLabel: selectedShareDateRangeLabel
                    )
                } label: {
                    Label("Share Pictures", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(snapshot.podcastBreakdown.isEmpty)

                NavigationLink(destination: ListeningTimeByPodcastChart()) {
                    Label("Listening Time by Podcast", systemImage: "chart.pie")
                }
                NavigationLink(destination: WeekListeningHeatMapView()) {
                    Label("Listening Heatmap", systemImage: "square.grid.3x3.fill")
                }
            }
        }
        .navigationTitle("Listening History")
        .listStyle(.insetGrouped)
        .task(id: refreshSignature) {
            refreshSnapshot()
        }
        .sheet(isPresented: $showPodcastShareSheet) {
            if let podcastShareImage {
                ShareSheet(activityItems: [podcastShareImage])
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
            .prefix(250)
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

        let listeningStatsInPeriod = fetchListeningStatsInPeriod(
            selectedPeriodStart: selectedPeriodStart,
            selectedPeriodEnd: selectedPeriodEnd,
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
            for session in selectedPeriodSessions {
                guard session.listenedSeconds > 0 else { continue }
                accumulateListening(
                    seconds: session.listenedSeconds,
                    on: session.startTime,
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

    private func rebuildAnalytics() {
        guard !isRebuildingAnalytics else { return }
        isRebuildingAnalytics = true
        rebuildStatusMessage = nil

        let container = modelContext.container
        Task.detached(priority: .utility) {
            await PlaySessionTrackerActor(modelContainer: container).rebuildListeningStats()
            await MainActor.run {
                isRebuildingAnalytics = false
                rebuildStatusMessage = "Analytics rebuilt."
                refreshSnapshot()
            }
        }
    }

    private func shareTopPodcasts(as design: TopPodcastShareDesign) {
        let rollups = Array(snapshot.podcastBreakdown.prefix(design.itemLimit))
        guard !rollups.isEmpty else { return }

        isPreparingPodcastShare = true
        Task {
            let items = await topPodcastShareItems(from: rollups)
            let renderedImage = renderTopPodcastShareImage(
                items: items,
                design: design,
                periodLabel: selectedPeriodLabel,
                dateRangeLabel: selectedShareDateRangeLabel,
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
            var descriptor = FetchDescriptor<PlaySessionSummary>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.periodStart, order: .reverse)]
            )
            return (try? modelContext.fetch(descriptor)) ?? []
        }()

        if !primary.isEmpty {
            return primary
        }

        var fallbackDescriptor = FetchDescriptor<PlaySessionSummary>(
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

private struct TopPodcastShareGalleryView: View {
    let rollups: [PodcastRollup]
    let periodLabel: String
    let dateRangeLabel: String

    @State private var renderedImages: [TopPodcastShareDesign: UIImage] = [:]
    @State private var selectedDesigns: Set<TopPodcastShareDesign> = []
    @State private var shareImages: [UIImage] = []
    @State private var showShareSheet = false
    @State private var isRendering = false

    private var availableDesigns: [TopPodcastShareDesign] {
        TopPodcastShareDesign.allCases.filter { rollups.count >= $0.minimumItemCount }
    }

    private var renderSignature: String {
        let rollupSignature = rollups.map { "\($0.id):\($0.totalSeconds)" }.joined(separator: "|")
        return "\(periodLabel)|\(dateRangeLabel)|\(rollupSignature)"
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
                    ForEach(availableDesigns) { design in
                        TopPodcastSharePreviewRow(
                            design: design,
                            image: renderedImages[design],
                            isSelected: selectedDesigns.contains(design),
                            isRendering: isRendering
                        ) {
                            toggleSelection(for: design)
                        } shareAction: {
                            share(designs: [design])
                        }
                    }
                } header: {
                    Text("Designs")
                } footer: {
                    Text(dateRangeLabel)
                }

                Section {
                    Button {
                        share(designs: Array(selectedDesigns))
                    } label: {
                        Label(
                            selectedDesigns.count <= 1 ? "Share Selected Image" : "Share Selected Images",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .disabled(selectedDesigns.isEmpty || selectedDesigns.contains { renderedImages[$0] == nil })
                }
            }
        }
        .navigationTitle("Share Pictures")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: renderSignature) {
            await renderPreviews()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: shareImages)
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
        let images = designs.compactMap { renderedImages[$0] }
        guard !images.isEmpty else { return }
        shareImages = images
        showShareSheet = true
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
        let maxLimit = neededDesigns.map(\.itemLimit).max() ?? 0
        let items = await topPodcastShareItems(from: Array(rollups.prefix(maxLimit)))

        var images: [TopPodcastShareDesign: UIImage] = [:]
        for design in neededDesigns {
            let designItems = Array(items.prefix(design.itemLimit))
            images[design] = renderTopPodcastShareImage(
                items: designItems,
                design: design,
                periodLabel: periodLabel,
                dateRangeLabel: dateRangeLabel,
                durationFormatter: formatDuration
            )
        }

        renderedImages = images
        selectedDesigns = Set(neededDesigns)
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

private struct TopPodcastSharePreviewRow: View {
    let design: TopPodcastShareDesign
    let image: UIImage?
    let isSelected: Bool
    let isRendering: Bool
    let selectAction: () -> Void
    let shareAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label(design.title, systemImage: design.systemImage)
                    .font(.headline)

                Spacer()

                Button(action: selectAction) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isSelected ? "Deselect \(design.title)" : "Select \(design.title)")

                Button(action: shareAction) {
                    Image(systemName: "square.and.arrow.up")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .disabled(image == nil)
                .accessibilityLabel("Share \(design.title)")
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .aspectRatio(1080 / 1350, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            .opacity(isRendering && image == nil ? 0.72 : 1)
        }
        .padding(.vertical, 8)
    }
}

private func topPodcastShareItems(from rollups: [PodcastRollup]) async -> [TopPodcastShareItem] {
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
private func renderTopPodcastShareImage(
    items: [TopPodcastShareItem],
    design: TopPodcastShareDesign,
    periodLabel: String,
    dateRangeLabel: String,
    durationFormatter: @escaping (Double) -> String
) -> UIImage? {
    let renderer = ImageRenderer(
        content: TopPodcastShareCard(
            items: items,
            design: design,
            periodLabel: periodLabel,
            dateRangeLabel: dateRangeLabel,
            durationFormatter: durationFormatter
        )
        .frame(width: 1080, height: 1350)
    )
    renderer.scale = 1
    return renderer.uiImage
}

private struct TopPodcastShareCard: View {
    let items: [TopPodcastShareItem]
    let design: TopPodcastShareDesign
    let periodLabel: String
    let dateRangeLabel: String
    let durationFormatter: (Double) -> String

    var body: some View {
        Group {
            switch design {
            case .podium:
                podiumCard
            case .billboard:
                billboardCard
            }
        }
        .foregroundStyle(.white)
    }

    private var podiumCard: some View {
        let podiumItems = [items[safe: 1], items[safe: 0], items[safe: 2]].compactMap(\.self)

        return ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.09, blue: 0.15),
                    Color(red: 0.04, green: 0.18, blue: 0.22),
                    Color(red: 0.47, green: 0.17, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 34) {
                shareHeader(title: "Top Podcast Podium", subtitle: periodLabel)

                HStack(alignment: .bottom, spacing: 28) {
                    ForEach(podiumItems) { item in
                        PodiumPodcastColumn(
                            item: item,
                            height: podiumHeight(for: item.rank),
                            duration: durationFormatter(item.totalSeconds)
                        )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 790, alignment: .bottom)

                footer
            }
            .padding(70)
        }
    }

    private var billboardCard: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.06, blue: 0.07),
                    Color(red: 0.16, green: 0.12, blue: 0.09),
                    Color(red: 0.64, green: 0.18, blue: 0.12)
                ],
                startPoint: .top,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 28) {
                shareHeader(title: "Podcast Top 10", subtitle: periodLabel)

                VStack(spacing: 14) {
                    ForEach(items.prefix(10)) { item in
                        BillboardPodcastRow(
                            item: item,
                            duration: durationFormatter(item.totalSeconds)
                        )
                    }
                }

                Spacer(minLength: 0)
                footer
            }
            .padding(58)
        }
    }

    private func shareHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 78, weight: .black, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.72)
            Text("Listening History • \(subtitle)")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))
        }
    }

    private var footer: some View {
        HStack {
            Text("Up Next")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Spacer()
            Text(dateRangeLabel)
                .font(.system(size: 24, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
        }
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

private struct PodiumPodcastColumn: View {
    let item: TopPodcastShareItem
    let height: CGFloat
    let duration: String

    var body: some View {
        VStack(spacing: 20) {
            PodcastShareArtwork(image: item.coverImage, size: item.rank == 1 ? 250 : 210)
                .shadow(color: .black.opacity(0.38), radius: 18, y: 16)

            VStack(spacing: 8) {
                Text(item.podcastName)
                    .font(.system(size: item.rank == 1 ? 34 : 28, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.72)
                Text(duration)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.74))
                    .monospacedDigit()
            }
            .frame(height: 120, alignment: .top)

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(item.rank == 1 ? 0.30 : 0.20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.white.opacity(0.18), lineWidth: 2)
                    )
                Text("#\(item.rank)")
                    .font(.system(size: 72, weight: .black, design: .rounded))
                    .padding(.top, 34)
            }
            .frame(height: height)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BillboardPodcastRow: View {
    let item: TopPodcastShareItem
    let duration: String

    var body: some View {
        HStack(spacing: 22) {
            Text("\(item.rank)")
                .font(.system(size: 42, weight: .black, design: .rounded))
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)

            PodcastShareArtwork(image: item.coverImage, size: 82)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.podcastName)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.76)
                Text(duration)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.66))
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(item.rank == 1 ? 0.20 : 0.12))
        )
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
        PlaySessionDebugView()
    }
}
