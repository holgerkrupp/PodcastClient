import SwiftUI
import SwiftData
import Charts
#if canImport(UIKit)
import UIKit
#endif

private struct ListeningOverviewPoint: Identifiable {
    let date: Date
    let totalSeconds: Double

    var id: Date { date }
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
        silenceGapTimeSavedSeconds: 0,
        playbackRateTimeSavedSeconds: 0,
        averagePeriodSeconds: 0,
        bestPeriod: nil,
        trackedDayCount: 0,
        averageTrackedDaySeconds: 0,
        bestTrackedDay: nil,
        trackingStartDate: nil,
        trackingEndDate: nil,
        podcastBreakdown: [],
        shareTimeline: [],
        selectedPeriodSessions: [],
        selectedPeriodSessionCount: 0,
        weekdayTotals: [],
        heatMap: .empty,
        isUsingSummaryTotals: false
    )

    let selectedPodcastTitle: String
    let groupedTotals: [PeriodListeningTotal]
    let chartPoints: [ListeningOverviewPoint]
    let selectedPeriodTotalSeconds: Double
    let totalListeningSeconds: Double
    let silenceGapTimeSavedSeconds: Double
    let playbackRateTimeSavedSeconds: Double
    let averagePeriodSeconds: Double
    let bestPeriod: PeriodListeningTotal?
    let trackedDayCount: Int
    let averageTrackedDaySeconds: Double
    let bestTrackedDay: PeriodListeningTotal?
    let trackingStartDate: Date?
    let trackingEndDate: Date?
    let podcastBreakdown: [PodcastRollup]
    let shareTimeline: [TopPodcastShareTimelineRollup]
    let selectedPeriodSessions: [RecentListeningSession]
    let selectedPeriodSessionCount: Int
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
    @State private var loadedSnapshotSignature = ""
    @State private var isPreparingPodcastShare = false
    @State private var isLoadingHistorySnapshot = false
    @State private var historyLoadingProgress: Double = 0
    @State private var historyLoadingMessage = "Loading listening history"
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
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent
        let symbols = formatter.shortWeekdaySymbols ?? Calendar.current.shortWeekdaySymbols
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
        selectedPeriod.singularTitle
    }

    private var selectedPeriodLabel: String {
        periodLabel(for: selectedPeriodStart, period: selectedPeriod)
    }

    private var selectedShareDateRangeLabel: String {
        if selectedPeriod == .forever {
            return foreverDateRangeLabel()
        }
        return periodDateRangeLabel(for: selectedPeriodStart, period: selectedPeriod)
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
            listeningSessionCount: snapshot.selectedPeriodSessionCount,
            busiestDayLabel: busiestDay.map { $0.totalSeconds > 0 ? $0.label : "No data yet" } ?? "No data yet",
            busiestHourLabel: busiestHourLabel(for: snapshot.heatMap)
        )
    }

    private var canMoveToNextPeriod: Bool {
        guard selectedPeriod != .forever else { return false }
        return selectedPeriodStart < periodStart(for: Date(), period: selectedPeriod)
    }

    private var refreshSignature: String {
        let podcastSignature = podcasts.prefix(3).map(\.title).joined(separator: "|")
        return "\(selectedPeriod.rawValue)|\(selectedPeriodStart.timeIntervalSinceReferenceDate)|\(selectedPodcastFeedString ?? "all")|\(podcasts.count)|\(podcastSignature)"
    }

    private var isShowingCurrentSnapshot: Bool {
        loadedSnapshotSignature == refreshSignature
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
                    .disabled(selectedPeriod == .forever)

                    Spacer(minLength: 8)

                    VStack(spacing: 2) {
                        Text(selectedPeriodLabel)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(isShowingCurrentSnapshot ? snapshot.selectedPodcastTitle : "Loading")
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

            if isLoadingHistorySnapshot || !isShowingCurrentSnapshot {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: historyLoadingProgress)
                            .progressViewStyle(.linear)
                        Text(historyLoadingMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section{
                NavigationLink {
                    TopPodcastShareGalleryView(
                        rollups: snapshot.podcastBreakdown,
                        timelineRollups: snapshot.shareTimeline,
                        period: selectedPeriod,
                        periodStart: selectedPeriodStart,
                        periodLabel: selectedSharePeriodLabel,
                        dateRangeLabel: selectedShareDateRangeLabel,
                        stats: selectedShareStats
                    )
                } label: {
                    Label("Share Top Podcasts", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(!isShowingCurrentSnapshot || snapshot.podcastBreakdown.isEmpty)
            }
            
            Section {

                
                LazyVGrid(columns: summaryGrid, spacing: 12) {
                    if !isShowingCurrentSnapshot {
                        summaryLoadingCard(title: selectedPeriod == .forever ? "Total Listening" : "Overview Listening")
                        summaryLoadingCard(title: selectedPeriod == .forever ? "Average Day" : "Average \(selectedPeriodSingular)")
                        summaryLoadingCard(title: selectedPeriod == .forever ? "Best Day" : "Best \(selectedPeriodSingular)")
                        summaryLoadingCard(title: selectedPeriod == .forever ? "First Listen" : selectedPeriodLabel)
                        summaryLoadingCard(title: "Silence Saved")
                        summaryLoadingCard(title: "Playback Speed Saved")
                    } else if selectedPeriod == .forever {
                        summaryCard(
                            title: "Total Listening",
                            value: formatDuration(snapshot.totalListeningSeconds),
                            detail: trackedDaysLabel(snapshot.trackedDayCount)
                        )
                        summaryCard(
                            title: "Average Day",
                            value: formatDuration(snapshot.averageTrackedDaySeconds),
                            detail: "Across tracked days"
                        )
                        summaryCard(
                            title: "Best Day",
                            value: snapshot.bestTrackedDay.map { formatDuration($0.totalSeconds) } ?? "None",
                            detail: snapshot.bestTrackedDay.map { localizedDateString(for: $0.start) } ?? "No data yet"
                        )
                        summaryCard(
                            title: "First Listen",
                            value: snapshot.trackingStartDate.map { localizedDateString(for: $0) } ?? "None",
                            detail: snapshot.trackingEndDate.map { "Latest \(localizedDateString(for: $0))" } ?? "No data yet"
                        )
                        timeSavedSummaryCards
                    } else {
                        summaryCard(
                            title: "Overview Listening",
                            value: formatDuration(snapshot.totalListeningSeconds),
                            detail: "All recorded listening"
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
                        timeSavedSummaryCards
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            if isShowingCurrentSnapshot && !snapshot.chartPoints.isEmpty {
                Section("Listening Trend") {
                    Text("Y-axis: listening time per \(listeningTrendUnitLabel).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Chart(snapshot.chartPoints) { point in
                        if usesAnnualListeningBars {
                            BarMark(
                                x: .value("Year", point.date, unit: .year),
                                y: .value("Listening", point.totalSeconds)
                            )
                            .foregroundStyle(.accent)
                            .cornerRadius(3)
                        } else {
                            AreaMark(
                                x: .value("Period", point.date),
                                y: .value("Listening", point.totalSeconds)
                            )
                            .foregroundStyle(.accent.opacity(0.22))
                            .interpolationMethod(.catmullRom)

                            LineMark(
                                x: .value("Period", point.date),
                                y: .value("Listening", point.totalSeconds)
                            )
                            .foregroundStyle(.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: listeningTrendXAxisDates) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(.secondary.opacity(0.35))
                            AxisTick()
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(listeningTrendXAxisLabel(for: date))
                                        .font(.caption2)
                                }
                            }
                        }
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

            if isShowingCurrentSnapshot && snapshot.heatMap.hasData {
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

            if isShowingCurrentSnapshot && selectedPodcastFeedString == nil && !snapshot.podcastBreakdown.isEmpty {
                Section {
                    NavigationLink {
                        TopPodcastShareGalleryView(
                            rollups: snapshot.podcastBreakdown,
                            timelineRollups: snapshot.shareTimeline,
                            period: selectedPeriod,
                            periodStart: selectedPeriodStart,
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
                if !isShowingCurrentSnapshot {
                    ContentUnavailableView(
                        "Loading History",
                        systemImage: "clock",
                        description: Text("Loading listening data for this \(selectedPeriodSingular.lowercased()).")
                    )
                } else if snapshot.groupedTotals.isEmpty {
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

                    if snapshot.selectedPeriodSessionCount > 15 {
                        NavigationLink {
                            ListeningSessionsListView(
                                sessions: snapshot.selectedPeriodSessions,
                                title: "\(selectedPeriodSingular) Sessions",
                                subtitle: selectedShareDateRangeLabel
                            )
                        } label: {
                            Label(
                                selectedPeriod == .forever ? "Show Recent Play Sessions" : "Show All Play Sessions",
                                systemImage: "list.bullet.rectangle"
                            )
                            .badge(snapshot.selectedPeriodSessionCount)
                        }
                    }
                }
            }

            if isShowingCurrentSnapshot && !snapshot.groupedTotals.isEmpty {
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
        .listStyle(.inset)
        .task(id: refreshSignature) {
            await refreshSnapshotWithLoading()
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
                    timelineRollups: snapshot.shareTimeline,
                    period: selectedPeriod,
                    periodStart: selectedPeriodStart,
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

    @MainActor
    private func refreshSnapshotWithLoading() async {
        let requestedSignature = refreshSignature
        historyLoadingProgress = selectedPeriod == .forever ? 0.08 : 0
        historyLoadingMessage = "Loading listening history"
        isLoadingHistorySnapshot = true
        await Task.yield()

        await refreshSnapshot(expectedSignature: requestedSignature)

        guard !Task.isCancelled, requestedSignature == refreshSignature else { return }
        loadedSnapshotSignature = requestedSignature
        historyLoadingProgress = 1
        historyLoadingMessage = "Listening history loaded"
        await Task.yield()
        isLoadingHistorySnapshot = false
    }

    @MainActor
    private func updateHistoryLoadingProgress(_ progress: Double, _ message: String) {
        guard isLoadingHistorySnapshot else { return }
        historyLoadingProgress = progress
        historyLoadingMessage = message
    }

    private func refreshSnapshot(expectedSignature: String) async {
        let selectedPeriodEnd = nextPeriodStart(from: selectedPeriodStart, period: selectedPeriod)
        let lookbackPeriods = overviewPeriodCount(for: selectedPeriod)
        let overviewStart = periodStartByAdding(-lookbackPeriods, to: selectedPeriodStart, period: selectedPeriod)
        let summaryFetchPeriod: PlaySessionSummaryPeriod = selectedPeriod == .forever ? .year : selectedPeriod
        let selectedPodcastURL = selectedPodcastFeedString.flatMap(URL.init(string:))
        let selectedPodcastTitle: String
        if let selectedPodcastFeedString {
            selectedPodcastTitle = podcasts.first(where: { $0.feed?.absoluteString == selectedPodcastFeedString })?.title ?? "Selected Podcast"
        } else {
            selectedPodcastTitle = "All Podcasts"
        }

        updateHistoryLoadingProgress(0.16, "Loading summary totals")
        await Task.yield()
        let fetchedSummaries = fetchSummariesInWindow(
            period: summaryFetchPeriod,
            overviewStart: overviewStart,
            selectedPeriodEnd: selectedPeriodEnd,
            selectedPodcastFeedString: selectedPodcastFeedString,
            selectedPodcastURL: selectedPodcastURL,
            lookbackPeriods: lookbackPeriods
        )

        updateHistoryLoadingProgress(0.32, "Loading play sessions")
        await Task.yield()
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
            return (periodStart(for: startTime, period: selectedPeriod == .forever ? .year : selectedPeriod), listened)
        }, by: \.0)
        .map { key, values in
            PeriodListeningTotal(start: key, totalSeconds: values.reduce(0) { $0 + $1.1 })
        }
        .sorted { $0.start > $1.start }

        let groupedTotals = summaryTotals.isEmpty ? rawSessionTotals : summaryTotals
        let overviewListeningSeconds = groupedTotals.reduce(0) { $0 + $1.totalSeconds }
        let averagePeriodSeconds = groupedTotals.isEmpty ? 0 : (overviewListeningSeconds / Double(groupedTotals.count))
        let totalListeningSeconds = lifetimeListeningSeconds(
            selectedPodcastFeedString: selectedPodcastFeedString,
            selectedPodcastURL: selectedPodcastURL
        )
        let chartPoints: [ListeningOverviewPoint]
        if selectedPeriod == .year {
            let monthlySummaries = fetchSummariesInWindow(
                period: .month,
                overviewStart: selectedPeriodStart,
                selectedPeriodEnd: selectedPeriodEnd,
                selectedPodcastFeedString: selectedPodcastFeedString,
                selectedPodcastURL: selectedPodcastURL,
                lookbackPeriods: 0
            )
            chartPoints = yearlyMonthlyChartPoints(
                summaries: monthlySummaries,
                sessions: sessionsInWindow,
                yearStart: selectedPeriodStart,
                yearEnd: selectedPeriodEnd
            )
        } else {
            chartPoints = Array(
                groupedTotals
                    .prefix(12)
                    .map { ListeningOverviewPoint(date: $0.start, totalSeconds: $0.totalSeconds) }
                    .reversed()
            )
        }

        let selectedPeriodRawSessions = sessionsInWindow
            .filter { session in
                guard let startTime = session.startTime else { return false }
                return startTime >= selectedPeriodStart && startTime < selectedPeriodEnd
            }
        let selectedPeriodSummaries = fetchedSummaries.filter { summary in
            guard let periodStart = summary.periodStart else { return false }
            if selectedPeriod == .forever {
                return true
            }
            return isSamePeriodStart(periodStart, as: selectedPeriodStart, period: selectedPeriod)
        }
        let summarySilenceGapTimeSavedSeconds = selectedPeriodSummaries.reduce(0) {
            $0 + ($1.silenceGapTimeSavedSeconds ?? 0)
        }
        let rawSilenceGapTimeSavedSeconds = selectedPeriodRawSessions.reduce(0) {
            $0 + max(0, $1.silenceGapTimeSavedSeconds ?? 0)
        }
        let summaryPlaybackRateTimeSavedSeconds = selectedPeriodSummaries.reduce(0) {
            $0 + ($1.playbackRateTimeSavedSeconds ?? 0)
        }
        let rawPlaybackRateTimeSavedSeconds = selectedPeriodRawSessions.reduce(0) {
            $0 + playbackRateTimeSaved(for: $1)
        }
        let silenceGapTimeSavedSeconds = summarySilenceGapTimeSavedSeconds > 0
            ? summarySilenceGapTimeSavedSeconds
            : rawSilenceGapTimeSavedSeconds
        let playbackRateTimeSavedSeconds = summaryPlaybackRateTimeSavedSeconds > 0
            ? summaryPlaybackRateTimeSavedSeconds
            : rawPlaybackRateTimeSavedSeconds

        let selectedPeriodSessionDisplayLimit = selectedPeriod == .forever ? 50 : Int.max
        let selectedPeriodSessions = selectedPeriodRawSessions
            .prefix(selectedPeriodSessionDisplayLimit)
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

        let calendar = Calendar.current
        let trackedDayTotals = Dictionary(grouping: selectedPeriodRawSessions.compactMap { session -> (Date, Double)? in
            guard let startTime = session.startTime else { return nil }
            let listened = listenedSeconds(for: session)
            guard listened > 0 else { return nil }
            return (calendar.startOfDay(for: startTime), listened)
        }, by: \.0)
        .map { key, values in
            PeriodListeningTotal(start: key, totalSeconds: values.reduce(0) { $0 + $1.1 })
        }
        .sorted { $0.start > $1.start }
        let trackedDayTotalSeconds = trackedDayTotals.reduce(0) { $0 + $1.totalSeconds }
        let trackedDayCount = trackedDayTotals.count
        let averageTrackedDaySeconds = trackedDayCount == 0 ? 0 : trackedDayTotalSeconds / Double(trackedDayCount)
        let trackingDates = selectedPeriodRawSessions.compactMap(\.startTime)

        let podcastBreakdown: [PodcastRollup]
        var shareTimeline: [TopPodcastShareTimelineRollup] = []
        var selectedPeriodListeningStatsForHabits: [ListeningStat]?
        if selectedPodcastFeedString == nil {
            updateHistoryLoadingProgress(0.48, "Preparing podcast totals")
            await Task.yield()
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

            updateHistoryLoadingProgress(0.60, "Preparing share timeline")
            await Task.yield()
            let selectedPeriodListeningStats = fetchListeningStatsInPeriod(
                selectedPeriodStart: selectedPeriodStart,
                selectedPeriodEnd: selectedPeriodEnd,
                selectedPodcastFeedString: nil,
                selectedPodcastURL: nil
            )
            if selectedPeriod != .day {
                selectedPeriodListeningStatsForHabits = selectedPeriodListeningStats
            }
            let selectedPeriodDaySummaries = fetchSummariesInWindow(
                period: .day,
                overviewStart: selectedPeriodStart,
                selectedPeriodEnd: selectedPeriodEnd,
                selectedPodcastFeedString: nil,
                selectedPodcastURL: nil,
                lookbackPeriods: 0
            )
            let selectedPeriodWeekSummaries = fetchSummariesInWindow(
                period: .week,
                overviewStart: selectedPeriodStart,
                selectedPeriodEnd: selectedPeriodEnd,
                selectedPodcastFeedString: nil,
                selectedPodcastURL: nil,
                lookbackPeriods: 0
            )
            let selectedPeriodMonthSummaries = fetchSummariesInWindow(
                period: .month,
                overviewStart: selectedPeriodStart,
                selectedPeriodEnd: selectedPeriodEnd,
                selectedPodcastFeedString: nil,
                selectedPodcastURL: nil,
                lookbackPeriods: 0
            )
            shareTimeline = shareTimelineRollups(
                stats: selectedPeriodListeningStats,
                sessions: selectedPeriodRawSessions,
                daySummaries: selectedPeriodDaySummaries,
                weekSummaries: selectedPeriodWeekSummaries,
                monthSummaries: selectedPeriodMonthSummaries,
                calendar: calendar,
                coversByFeed: podcastCoversByFeed,
                coversByTitle: podcastCoversByTitle
            )

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

        let selectedPeriodTotalSeconds = selectedPeriod == .forever
            ? totalListeningSeconds
            : groupedTotals.first(where: {
                isSamePeriodStart($0.start, as: selectedPeriodStart, period: selectedPeriod)
            })?.totalSeconds ?? selectedPeriodSessions.reduce(0) { $0 + $1.listenedSeconds }

        var weekdaySeconds: [Int: Double] = [:]
        var secondsByWeekday = Dictionary(uniqueKeysWithValues: weekdayOrder.map { ($0, Array(repeating: 0.0, count: 24)) })

        let listeningHabitsStart = selectedPeriod == .day
            ? periodStart(for: selectedPeriodStart, period: .week)
            : selectedPeriodStart
        let listeningHabitsEnd = selectedPeriod == .day
            ? nextPeriodStart(from: listeningHabitsStart, period: .week)
            : selectedPeriodEnd

        updateHistoryLoadingProgress(0.78, "Preparing listening habits")
        await Task.yield()
        let listeningStatsInPeriod = selectedPeriodListeningStatsForHabits ?? fetchListeningStatsInPeriod(
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

        updateHistoryLoadingProgress(0.92, "Updating listening history")
        await Task.yield()
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

        guard !Task.isCancelled, expectedSignature == refreshSignature else { return }
        snapshot = ListeningHistorySnapshot(
            selectedPodcastTitle: selectedPodcastTitle,
            groupedTotals: groupedTotals,
            chartPoints: chartPoints,
            selectedPeriodTotalSeconds: selectedPeriodTotalSeconds,
            totalListeningSeconds: totalListeningSeconds,
            silenceGapTimeSavedSeconds: silenceGapTimeSavedSeconds,
            playbackRateTimeSavedSeconds: playbackRateTimeSavedSeconds,
            averagePeriodSeconds: averagePeriodSeconds,
            bestPeriod: groupedTotals.max { $0.totalSeconds < $1.totalSeconds },
            trackedDayCount: trackedDayCount,
            averageTrackedDaySeconds: averageTrackedDaySeconds,
            bestTrackedDay: trackedDayTotals.max { $0.totalSeconds < $1.totalSeconds },
            trackingStartDate: trackingDates.min(),
            trackingEndDate: trackingDates.max(),
            podcastBreakdown: podcastBreakdown,
            shareTimeline: shareTimeline,
            selectedPeriodSessions: Array(selectedPeriodSessions),
            selectedPeriodSessionCount: selectedPeriodRawSessions.count,
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
                period: selectedPeriod,
                periodStart: selectedPeriodStart,
                timelineEntries: [],
                usesMonthlyMiniMonthBackgrounds: false,
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

    private func shareTimelineRollups(
        stats: [ListeningStat],
        sessions: [PlaySession],
        daySummaries: [PlaySessionSummary],
        weekSummaries: [PlaySessionSummary],
        monthSummaries: [PlaySessionSummary],
        calendar: Calendar,
        coversByFeed: [String: URL?],
        coversByTitle: [String: URL?]
    ) -> [TopPodcastShareTimelineRollup] {
        let statRollups = stats.compactMap { stat -> TopPodcastShareTimelineRollup? in
            guard let date = stat.startOfHour, let totalSeconds = stat.totalSeconds, totalSeconds > 0 else { return nil }
            let feed = stat.podcastFeed
            let name = stat.podcastName ?? "Unknown Podcast"
            return TopPodcastShareTimelineRollup(
                date: date,
                podcastName: name,
                podcastFeed: feed,
                coverURL: feed.flatMap { coversByFeed[$0.absoluteString] ?? nil } ?? coversByTitle[name] ?? nil,
                totalSeconds: totalSeconds
            )
        }

        let daysWithHourlyStats = Set(statRollups.map { calendar.startOfDay(for: $0.date) })
        let summaryRollups = daySummaries.compactMap { summary -> TopPodcastShareTimelineRollup? in
            guard
                let date = summary.periodStart,
                !daysWithHourlyStats.contains(calendar.startOfDay(for: date)),
                let totalSeconds = summary.totalSeconds,
                totalSeconds > 0
            else {
                return nil
            }

            let feed = summary.podcastFeed
            let name = summary.podcastName ?? "Unknown Podcast"
            return TopPodcastShareTimelineRollup(
                date: date,
                podcastName: name,
                podcastFeed: feed,
                coverURL: feed.flatMap { coversByFeed[$0.absoluteString] ?? nil } ?? coversByTitle[name] ?? nil,
                totalSeconds: totalSeconds
            )
        }

        let weekRollups = fallbackSummaryRollups(
            summaries: weekSummaries,
            period: .week,
            existingRollups: statRollups + summaryRollups,
            calendar: calendar,
            coversByFeed: coversByFeed,
            coversByTitle: coversByTitle
        )
        let monthRollups = fallbackSummaryRollups(
            summaries: monthSummaries,
            period: .month,
            existingRollups: statRollups + summaryRollups + weekRollups,
            calendar: calendar,
            coversByFeed: coversByFeed,
            coversByTitle: coversByTitle
        )

        let persistedRollups = (statRollups + summaryRollups + weekRollups + monthRollups).sorted { $0.date < $1.date }
        if !persistedRollups.isEmpty {
            return persistedRollups
        }

        return sessions.compactMap { session -> TopPodcastShareTimelineRollup? in
            guard let startTime = session.startTime else { return nil }
            let totalSeconds = listenedSeconds(for: session)
            guard totalSeconds > 0 else { return nil }
            let feed = session.episode?.podcast?.feed
            let name = session.podcastName ?? "Unknown Podcast"
            let hourStart = calendar.dateInterval(of: .hour, for: startTime)?.start ?? startTime
            return TopPodcastShareTimelineRollup(
                date: hourStart,
                podcastName: name,
                podcastFeed: feed,
                coverURL: feed.flatMap { coversByFeed[$0.absoluteString] ?? nil } ?? coversByTitle[name] ?? nil,
                totalSeconds: totalSeconds
            )
        }
        .sorted { $0.date < $1.date }
    }

    private func fallbackSummaryRollups(
        summaries: [PlaySessionSummary],
        period: PlaySessionSummaryPeriod,
        existingRollups: [TopPodcastShareTimelineRollup],
        calendar: Calendar,
        coversByFeed: [String: URL?],
        coversByTitle: [String: URL?]
    ) -> [TopPodcastShareTimelineRollup] {
        summaries.compactMap { summary -> TopPodcastShareTimelineRollup? in
            guard
                let date = summary.periodStart,
                let totalSeconds = summary.totalSeconds,
                totalSeconds > 0,
                !existingRollups.contains(where: { rollup in
                    rollup.podcastFeed == summary.podcastFeed
                    && isDate(rollup.date, inPeriodStarting: date, period: period, calendar: calendar)
                })
            else {
                return nil
            }

            let feed = summary.podcastFeed
            let name = summary.podcastName ?? "Unknown Podcast"
            return TopPodcastShareTimelineRollup(
                date: date,
                podcastName: name,
                podcastFeed: feed,
                coverURL: feed.flatMap { coversByFeed[$0.absoluteString] ?? nil } ?? coversByTitle[name] ?? nil,
                totalSeconds: totalSeconds,
                coveragePeriod: period
            )
        }
    }

    private func isDate(
        _ date: Date,
        inPeriodStarting periodStart: Date,
        period: PlaySessionSummaryPeriod,
        calendar: Calendar
    ) -> Bool {
        let end: Date
        switch period {
        case .day:
            end = calendar.date(byAdding: .day, value: 1, to: periodStart) ?? periodStart
        case .week:
            end = calendar.date(byAdding: .weekOfYear, value: 1, to: periodStart) ?? periodStart
        case .month:
            end = calendar.date(byAdding: .month, value: 1, to: periodStart) ?? periodStart
        case .year:
            end = calendar.date(byAdding: .year, value: 1, to: periodStart) ?? periodStart
        case .forever:
            end = .distantFuture
        }
        return date >= periodStart && date < end
    }

    private func trackedDaysLabel(_ count: Int) -> String {
        count == 1 ? "1 day tracked" : "\(count) days tracked"
    }

    private var usesAnnualListeningBars: Bool {
        selectedPeriod == .forever
    }

    private var listeningTrendUnitLabel: String {
        switch selectedPeriod {
        case .year:
            return "month"
        case .forever:
            return "year"
        default:
            return selectedPeriodSingular.lowercased()
        }
    }

    private var listeningTrendXAxisDates: [Date] {
        guard usesAnnualListeningBars else {
            return snapshot.chartPoints.map(\.date)
        }

        let calendar = Calendar.current
        guard
            let firstDate = snapshot.chartPoints.map(\.date).min(),
            let lastDate = snapshot.chartPoints.map(\.date).max()
        else {
            return []
        }

        let firstYear = calendar.component(.year, from: firstDate)
        let lastYear = calendar.component(.year, from: lastDate)
        return (firstYear...lastYear).compactMap { year in
            calendar.date(from: DateComponents(year: year))
        }
    }

    private func listeningTrendXAxisLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent

        switch selectedPeriod {
        case .day:
            formatter.setLocalizedDateFormatFromTemplate("ddMMM")
            return formatter.string(from: date)
        case .week:
            let week = Calendar.current.component(.weekOfYear, from: date)
            return String(format: "W%02d", week)
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("MMM")
            return formatter.string(from: date)
        case .year:
            formatter.setLocalizedDateFormatFromTemplate("MMM")
            return formatter.string(from: date)
        case .forever:
            formatter.setLocalizedDateFormatFromTemplate("yyyy")
            return formatter.string(from: date)
        }
    }

    private func yearlyMonthlyChartPoints(
        summaries: [PlaySessionSummary],
        sessions: [PlaySession],
        yearStart: Date,
        yearEnd: Date
    ) -> [ListeningOverviewPoint] {
        let calendar = Calendar.current
        let summaryTotals = Dictionary(grouping: summaries.compactMap { summary -> (Date, Double)? in
            guard let start = summary.periodStart else { return nil }
            return (periodStart(for: start, period: .month), summary.totalSeconds ?? 0)
        }, by: \.0)
        .mapValues { values in
            values.reduce(0) { $0 + $1.1 }
        }

        let rawTotals = Dictionary(grouping: sessions.compactMap { session -> (Date, Double)? in
            guard
                let start = session.startTime,
                start >= yearStart,
                start < yearEnd
            else {
                return nil
            }
            return (periodStart(for: start, period: .month), listenedSeconds(for: session))
        }, by: \.0)
        .mapValues { values in
            values.reduce(0) { $0 + $1.1 }
        }

        let totals = summaryTotals.isEmpty ? rawTotals : summaryTotals
        let currentMonthStart = periodStart(for: Date(), period: .month)
        let finalMonthStart: Date
        if calendar.isDate(yearStart, equalTo: Date(), toGranularity: .year) {
            finalMonthStart = currentMonthStart
        } else {
            finalMonthStart = calendar.date(byAdding: .month, value: -1, to: yearEnd) ?? yearStart
        }

        var points: [ListeningOverviewPoint] = []
        var monthStart = yearStart
        while monthStart <= finalMonthStart && monthStart < yearEnd {
            points.append(
                ListeningOverviewPoint(
                    date: monthStart,
                    totalSeconds: totals[monthStart] ?? 0
                )
            )
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
                break
            }
            monthStart = nextMonth
        }
        return points
    }

    private func summaryLoadingCard(title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView()
                .controlSize(.small)
            Text("Loading")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    @ViewBuilder
    private var timeSavedSummaryCards: some View {
        summaryCard(
            title: "Silence Saved",
            value: formatSavedDuration(snapshot.silenceGapTimeSavedSeconds),
            detail: "By reducing silence gaps"
        )
        summaryCard(
            title: "Playback Speed Saved",
            value: formatSavedDuration(snapshot.playbackRateTimeSavedSeconds),
            detail: "By listening above 1x"
        )
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
                .fill(Color.secondary.opacity(0.12))
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

    private func playbackRateTimeSaved(for session: PlaySession) -> Double {
        PlaybackRateSavingsCalculator.secondsSaved(in: session)
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

    private func formatSavedDuration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0s" }
        if seconds < 60 {
            return "\(Int(seconds.rounded()))s"
        }
        return formatDuration(seconds)
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
            return localizedDateString(for: date)
        case .week:
            let end = Calendar.current.date(byAdding: .day, value: 6, to: date) ?? date
            return dateRangeLabel(start: date, end: end)
        case .month:
            return localizedMonthYearString(for: date)
        case .year:
            return localizedYearString(for: date)
        case .forever:
            return "Forever"
        }
    }

    private func sharePeriodLabel(for date: Date, period: PlaySessionSummaryPeriod) -> String {
        switch period {
        case .day:
            return localizedDateString(for: date)
        case .week:
            let end = Calendar.current.date(byAdding: .day, value: 6, to: date) ?? date
            return dateRangeLabel(start: date, end: end)
        case .month:
            return localizedMonthYearString(for: date)
        case .year:
            return localizedYearString(for: date)
        case .forever:
            return "Forever"
        }
    }

    private func periodDateRangeLabel(for date: Date, period: PlaySessionSummaryPeriod) -> String {
        if period == .forever {
            return foreverDateRangeLabel()
        }
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

    private func foreverDateRangeLabel() -> String {
        let preciseDates = snapshot.shareTimeline.map(\.date)
            + snapshot.selectedPeriodSessions.map(\.startTime)
        let summaryStarts = snapshot.groupedTotals.map(\.start)

        let start = preciseDates.min() ?? summaryStarts.min()
        guard let start else {
            return "All time"
        }

        let summaryEnds = summaryStarts.map { calendarEnd(for: $0, period: .year) }
        let end = preciseDates.max() ?? summaryEnds.max() ?? start
        return dateRangeLabel(start: start, end: end)
    }

    private func calendarEnd(for start: Date, period: PlaySessionSummaryPeriod) -> Date {
        let calendar = Calendar.current
        let exclusiveEnd = nextPeriodStart(from: start, period: period)
        return calendar.date(byAdding: .day, value: -1, to: exclusiveEnd) ?? start
    }

    private func localizedDateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func localizedMonthYearString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMMM y")
        return formatter.string(from: date)
    }

    private func localizedYearString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("y")
        return formatter.string(from: date)
    }

    private func dateRangeLabel(start: Date, end: Date) -> String {
        let calendar = Calendar.current
        let cappedEnd = min(end, calendar.startOfDay(for: Date()))
        if calendar.isDate(start, inSameDayAs: cappedEnd) {
            return localizedDateString(for: start)
        }

        let formatter = DateIntervalFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: start, to: cappedEnd)
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
        case .forever:
            return .distantPast
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
        case .forever:
            return .distantFuture
        }

        let next = calendar.date(byAdding: unit, value: 1, to: date) ?? date
        return periodStart(for: next, period: period)
    }

    private func moveSelectedPeriod(by amount: Int) {
        guard selectedPeriod != .forever else { return }
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
        case .forever:
            return
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
        case .forever:
            return .distantPast
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
        case .forever:
            return 0
        }
    }

    private func lifetimeListeningSeconds(
        selectedPodcastFeedString: String?,
        selectedPodcastURL: URL?
    ) -> Double {
        if StoreDevelopmentConfiguration.newStoreReadsEnabled,
           let syncedTotal = syncedLifetimeListeningSeconds(
               selectedPodcastFeedString: selectedPodcastFeedString
           ) {
            return syncedTotal
        }
        let endOfToday = Calendar.current.date(
            byAdding: .day,
            value: 1,
            to: Calendar.current.startOfDay(for: Date())
        ) ?? Date().addingTimeInterval(86_400)
        let summaries = fetchSummariesInWindow(
            period: .year,
            overviewStart: .distantPast,
            selectedPeriodEnd: endOfToday,
            selectedPodcastFeedString: selectedPodcastFeedString,
            selectedPodcastURL: selectedPodcastURL,
            lookbackPeriods: 0
        )
        if !summaries.isEmpty {
            return summaries.reduce(0) { $0 + max(0, $1.totalSeconds ?? 0) }
        }

        return fetchSessionsInWindow(
            overviewStart: .distantPast,
            selectedPeriodEnd: endOfToday,
            selectedPodcastFeedString: selectedPodcastFeedString
        ).reduce(0) { $0 + listenedSeconds(for: $1) }
    }

    private func syncedLifetimeListeningSeconds(
        selectedPodcastFeedString: String?
    ) -> Double? {
        guard let container = ModelContainerManager.shared.preparedUserStateContainer else {
            return nil
        }
        let context = ModelContext(container)
        let summaries = (try? context.fetch(
            FetchDescriptor<ListeningSummarySync>()
        )) ?? []
        func summariesForSelectedFeed(
            kind: PlaySessionSummaryPeriod
        ) -> [ListeningSummarySync] {
            let matching = summaries.filter { $0.periodKind == kind.rawValue }
            guard let selectedPodcastFeedString,
                  let selectedURL = URL(string: selectedPodcastFeedString) else {
                return matching
            }
            let selectedKeys = selectedURL.podcastFeedComparisonKeys
            return matching.filter { record in
                guard let feed = URL(string: record.feedURL) else { return false }
                return feed.podcastFeedComparisonKeys.isDisjoint(with: selectedKeys) == false
            }
        }

        // Prefer the `.forever` rollup (a single non-overlapping lifetime total),
        // then fall back to the `.year` summaries — which also partition time
        // without overlap, so summing them never double-counts. The `.year` tier
        // keeps stores migrated before `.forever` rollups were synthesised from
        // reporting only the retained raw sessions instead of the full lifetime.
        for kind in [PlaySessionSummaryPeriod.forever, .year] {
            let scoped = summariesForSelectedFeed(kind: kind)
            if scoped.isEmpty == false {
                return ListeningSummaryAggregation.globalStatistics(
                    from: scoped
                ).totalSeconds
            }
        }

        let selectedKeys = selectedPodcastFeedString
            .flatMap(URL.init(string:))
            .map(\.podcastFeedComparisonKeys)
        let pageSize = 250
        var offset = 0
        var newestByIdentity: [String: ListeningHistorySync] = [:]

        while true {
            var descriptor = FetchDescriptor<ListeningHistorySync>()
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = pageSize
            let page = (try? context.fetch(descriptor)) ?? []
            guard page.isEmpty == false else { break }

            let filteredPage: [ListeningHistorySync]
            if let selectedKeys {
                filteredPage = page.filter { record in
                    guard let feed = URL(string: record.feedURL) else { return false }
                    return feed.podcastFeedComparisonKeys.isDisjoint(with: selectedKeys) == false
                }
            } else {
                filteredPage = page
            }

            for record in filteredPage {
                let key = ListeningHistoryIdentity.canonicalAggregationKey(for: record)
                if let existing = newestByIdentity[key] {
                    let shouldReplace: Bool
                    if record.updatedAt != existing.updatedAt {
                        shouldReplace = record.updatedAt > existing.updatedAt
                    } else if record.endedAt != existing.endedAt {
                        shouldReplace = record.endedAt > existing.endedAt
                    } else if record.listenedSeconds != existing.listenedSeconds {
                        shouldReplace = record.listenedSeconds > existing.listenedSeconds
                    } else {
                        shouldReplace = record.sourceDeviceID < existing.sourceDeviceID
                    }
                    if shouldReplace {
                        newestByIdentity[key] = record
                    }
                } else {
                    newestByIdentity[key] = record
                }
            }

            offset += page.count
            if page.count < pageSize {
                break
            }
        }
        guard newestByIdentity.isEmpty == false else { return nil }
        return newestByIdentity.values.reduce(0) { partial, record in
            partial + max(0, record.listenedSeconds)
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
        let isAllTime = overviewStart == .distantPast
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
            if !isAllTime {
                descriptor.fetchLimit = 2500
            }
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
        if !isAllTime {
            fallbackDescriptor.fetchLimit = 5000
        }
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
        let isAllTime = selectedPeriodStart == .distantPast
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
        if !isAllTime {
            fallbackDescriptor.fetchLimit = 24 * 90
        }
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
        case .forever:
            return true
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
        .listStyle(.inset)
        .navigationTitle(title)
        .platformInlineNavigationTitle()
    }
}

#Preview {
    NavigationStack {
        StatisticsView()
    }
}
