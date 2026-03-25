import SwiftUI
import SwiftData
import Charts

private struct ListeningOverviewPoint: Identifiable {
    let date: Date
    let totalSeconds: Double

    var id: Date { date }
}

private struct PodcastRollup: Identifiable {
    let podcastName: String
    let totalSeconds: Double

    var id: String { podcastName }
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
        totalListeningSeconds: 0,
        averagePeriodSeconds: 0,
        bestPeriod: nil,
        podcastBreakdown: [],
        recentSessions: [],
        weekdayTotals: [],
        heatMap: .empty,
        isUsingSummaryTotals: false
    )

    let selectedPodcastTitle: String
    let groupedTotals: [PeriodListeningTotal]
    let chartPoints: [ListeningOverviewPoint]
    let totalListeningSeconds: Double
    let averagePeriodSeconds: Double
    let bestPeriod: PeriodListeningTotal?
    let podcastBreakdown: [PodcastRollup]
    let recentSessions: [RecentListeningSession]
    let weekdayTotals: [WeekdayListeningTotal]
    let heatMap: ListeningHeatMapSnapshot
    let isUsingSummaryTotals: Bool
}

struct PlaySessionDebugView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PlaySessionSummary.periodStart, order: .reverse) private var summaries: [PlaySessionSummary]
    @Query(sort: \PlaySession.startTime, order: .reverse) private var sessions: [PlaySession]
    @Query(sort: \ListeningStat.startOfHour, order: .reverse) private var listeningStats: [ListeningStat]
    @Query(sort: \Podcast.title) private var podcasts: [Podcast]

    @State private var selectedPeriod: PlaySessionSummaryPeriod = .week
    @State private var selectedPodcastFeedString: String? = nil
    @State private var hasTriggeredRebuild = false
    @State private var snapshot = ListeningHistorySnapshot.empty

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

    private var shouldRebuildAnalytics: Bool {
        !hasTriggeredRebuild && summaries.isEmpty && !sessions.isEmpty
    }

    private var statisticsSignature: String {
        let firstSummary = summaries.first
        let firstSession = sessions.first
        let firstStat = listeningStats.first
        let firstPodcast = podcasts.first
        let summarySignature = "\(signatureValue(firstSummary?.id))|\(signatureValue(firstSummary?.periodStart))|\(signatureValue(firstSummary?.totalSeconds))"
        let sessionSignature = "\(signatureValue(firstSession?.id))|\(signatureValue(firstSession?.startTime))|\(signatureValue(firstSession?.endTime))"
        let statSignature = "\(signatureValue(firstStat?.id))|\(signatureValue(firstStat?.startOfHour))|\(signatureValue(firstStat?.totalSeconds))"
        let podcastSignature = "\(signatureValue(firstPodcast?.id))|\(firstPodcast?.title ?? "")"

        return "\(selectedPeriod.rawValue)|\(selectedPodcastFeedString ?? "all")|\(summaries.count)|\(summarySignature)|\(sessions.count)|\(sessionSignature)|\(listeningStats.count)|\(statSignature)|\(podcasts.count)|\(podcastSignature)"
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
                        title: "Recent Sessions",
                        value: "\(snapshot.recentSessions.count)",
                        detail: snapshot.isUsingSummaryTotals ? "Detailed history kept for the newest sessions" : "Showing live data from raw sessions"
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
                Section("Top Podcasts") {
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
                }
            }

            Section("\(selectedPeriod.title) History") {
                if snapshot.groupedTotals.isEmpty {
                    ContentUnavailableView(
                        "No Listening History",
                        systemImage: "chart.bar.xaxis",
                        description: Text("Start listening to see your summarized playback history here.")
                    )
                } else {
                    ForEach(snapshot.groupedTotals) { item in
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

            Section("Recent Session History") {
                ForEach(snapshot.recentSessions) { session in
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

            Section("More Views") {
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
        .task(id: statisticsSignature) {
            refreshSnapshot()
            rebuildAnalyticsIfNeeded()
        }
    }

    private func refreshSnapshot() {
        let selectedPodcastTitle: String
        if let selectedPodcastFeedString {
            selectedPodcastTitle = podcasts.first(where: { $0.feed?.absoluteString == selectedPodcastFeedString })?.title ?? "Selected Podcast"
        } else {
            selectedPodcastTitle = "All Podcasts"
        }

        let filteredSummaries = summaries.filter { summary in
            summary.periodKind == selectedPeriod.rawValue
            && (selectedPodcastFeedString == nil || summary.podcastFeed?.absoluteString == selectedPodcastFeedString)
        }
        let filteredSessions = sessions.filter { session in
            selectedPodcastFeedString == nil || session.episode?.podcast?.feed?.absoluteString == selectedPodcastFeedString
        }
        let filteredListeningStats = listeningStats.filter { stat in
            selectedPodcastFeedString == nil || stat.podcastFeed?.absoluteString == selectedPodcastFeedString
        }

        let summaryTotals = Dictionary(grouping: filteredSummaries.compactMap { summary -> (Date, Double)? in
            guard let periodStart = summary.periodStart else { return nil }
            return (periodStart, summary.totalSeconds ?? 0)
        }, by: \.0)
        .map { key, values in
            PeriodListeningTotal(start: key, totalSeconds: values.reduce(0) { $0 + $1.1 })
        }
        .sorted { $0.start > $1.start }

        let rawSessionTotals = Dictionary(grouping: filteredSessions.compactMap { session -> (Date, Double)? in
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

        let podcastBreakdown: [PodcastRollup]
        if !filteredSummaries.isEmpty {
            podcastBreakdown = Dictionary(grouping: filteredSummaries.compactMap { summary -> (String, Double)? in
                guard let name = summary.podcastName, let seconds = summary.totalSeconds, seconds > 0 else { return nil }
                return (name, seconds)
            }, by: \.0)
            .map { name, values in
                PodcastRollup(podcastName: name, totalSeconds: values.reduce(0) { $0 + $1.1 })
            }
            .sorted { $0.totalSeconds > $1.totalSeconds }
        } else if selectedPodcastFeedString == nil {
            podcastBreakdown = Dictionary(grouping: filteredSessions.compactMap { session -> (String, Double)? in
                let listened = listenedSeconds(for: session)
                guard listened > 0 else { return nil }
                return (session.podcastName ?? "Unknown Podcast", listened)
            }, by: \.0)
            .map { name, values in
                PodcastRollup(podcastName: name, totalSeconds: values.reduce(0) { $0 + $1.1 })
            }
            .sorted { $0.totalSeconds > $1.totalSeconds }
        } else {
            podcastBreakdown = []
        }

        let recentSessions = Array(filteredSessions.prefix(20)).map { session in
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

        var weekdaySeconds: [Int: Double] = [:]
        var secondsByWeekday = Dictionary(uniqueKeysWithValues: weekdayOrder.map { ($0, Array(repeating: 0.0, count: 24)) })
        let calendar = Calendar.current

        if !filteredListeningStats.isEmpty {
            for stat in filteredListeningStats {
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
            for session in filteredSessions {
                guard let startTime = session.startTime else { continue }
                let totalSeconds = listenedSeconds(for: session)
                guard totalSeconds > 0 else { continue }
                accumulateListening(
                    seconds: totalSeconds,
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
            totalListeningSeconds: totalListeningSeconds,
            averagePeriodSeconds: averagePeriodSeconds,
            bestPeriod: groupedTotals.max { $0.totalSeconds < $1.totalSeconds },
            podcastBreakdown: podcastBreakdown,
            recentSessions: recentSessions,
            weekdayTotals: weekdayTotals,
            heatMap: heatMap,
            isUsingSummaryTotals: !summaryTotals.isEmpty
        )
    }

    private func rebuildAnalyticsIfNeeded() {
        guard shouldRebuildAnalytics else { return }
        hasTriggeredRebuild = true
        let container = modelContext.container
        Task {
            await PlaySessionTrackerActor(modelContainer: container).rebuildListeningStats()
        }
    }

    private func signatureValue<T>(_ value: T?) -> String {
        value.map { String(describing: $0) } ?? ""
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Hour By Weekday")
                .font(.subheadline.weight(.semibold))

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("")
                        .font(.caption2)
                        .frame(height: 16)
                    ForEach(0..<24, id: \.self) { hour in
                        Text(String(format: "%02d", hour))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(height: 12)
                    }
                }

                ForEach(Array(weekdayOrder.enumerated()), id: \.offset) { index, weekday in
                    VStack(spacing: 4) {
                        Text(weekdayLabels[index])
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(height: 16)

                        ForEach(0..<24, id: \.self) { hour in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(heatColor(for: snapshot.heatMap.seconds(weekday: weekday, hour: hour)))
                                .frame(width: 22, height: 12)
                        }
                    }
                }
            }

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

    private func heatColor(for seconds: Double) -> Color {
        let intensity = min(max(seconds / snapshot.heatMap.maxSeconds, 0), 1)
        return Color.accentColor.opacity(0.12 + intensity * 0.88)
    }
}

#Preview {
    NavigationStack {
        PlaySessionDebugView()
    }
}
