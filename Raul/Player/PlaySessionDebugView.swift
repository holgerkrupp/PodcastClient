import SwiftUI
import SwiftData
import Charts

private struct ListeningOverviewPoint: Identifiable {
    let id = UUID()
    let date: Date
    let totalSeconds: Double
}

private struct PodcastRollup: Identifiable {
    let id = UUID()
    let podcastName: String
    let totalSeconds: Double
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

private struct ListeningHabitCell: Identifiable {
    let weekday: Int
    let hour: Int
    let totalSeconds: Double

    var id: String { "\(weekday)-\(hour)" }
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

    private var selectedPodcastTitle: String {
        guard let selectedPodcastFeedString else { return "All Podcasts" }
        return podcasts.first(where: { $0.feed?.absoluteString == selectedPodcastFeedString })?.title ?? "Selected Podcast"
    }

    private var filteredSummaries: [PlaySessionSummary] {
        summaries.filter { summary in
            summary.periodKind == selectedPeriod.rawValue
            && (selectedPodcastFeedString == nil || summary.podcastFeed?.absoluteString == selectedPodcastFeedString)
        }
    }

    private var filteredSessions: [PlaySession] {
        sessions.filter { session in
            selectedPodcastFeedString == nil || session.episode?.podcast?.feed?.absoluteString == selectedPodcastFeedString
        }
    }

    private var summaryTotals: [PeriodListeningTotal] {
        Dictionary(grouping: filteredSummaries.compactMap { summary -> (Date, Double)? in
            guard let periodStart = summary.periodStart else { return nil }
            return (periodStart, summary.totalSeconds ?? 0)
        }, by: \.0)
        .map { key, values in
            PeriodListeningTotal(start: key, totalSeconds: values.reduce(0) { $0 + $1.1 })
        }
        .sorted { $0.start > $1.start }
    }

    private var rawSessionTotals: [PeriodListeningTotal] {
        Dictionary(grouping: filteredSessions.compactMap { session -> (Date, Double)? in
            guard let startTime = session.startTime else { return nil }
            let listened = listenedSeconds(for: session)
            guard listened > 0 else { return nil }
            return (periodStart(for: startTime, period: selectedPeriod), listened)
        }, by: \.0)
        .map { key, values in
            PeriodListeningTotal(start: key, totalSeconds: values.reduce(0) { $0 + $1.1 })
        }
        .sorted { $0.start > $1.start }
    }

    private var groupedTotals: [PeriodListeningTotal] {
        summaryTotals.isEmpty ? rawSessionTotals : summaryTotals
    }

    private var chartPoints: [ListeningOverviewPoint] {
        groupedTotals
            .prefix(12)
            .map { ListeningOverviewPoint(date: $0.start, totalSeconds: $0.totalSeconds) }
            .reversed()
    }

    private var totalListeningSeconds: Double {
        groupedTotals.reduce(0) { $0 + $1.totalSeconds }
    }

    private var averagePeriodSeconds: Double {
        guard !groupedTotals.isEmpty else { return 0 }
        return totalListeningSeconds / Double(groupedTotals.count)
    }

    private var bestPeriod: PeriodListeningTotal? {
        groupedTotals.max { $0.totalSeconds < $1.totalSeconds }
    }

    private var podcastBreakdown: [PodcastRollup] {
        if !filteredSummaries.isEmpty {
            return Dictionary(grouping: filteredSummaries.compactMap { summary -> (String, Double)? in
                guard let name = summary.podcastName, let seconds = summary.totalSeconds, seconds > 0 else { return nil }
                return (name, seconds)
            }, by: \.0)
            .map { name, values in
                PodcastRollup(podcastName: name, totalSeconds: values.reduce(0) { $0 + $1.1 })
            }
            .sorted { $0.totalSeconds > $1.totalSeconds }
        }

        return Dictionary(grouping: sessions.compactMap { session -> (String, Double)? in
            guard selectedPodcastFeedString == nil else { return nil }
            let listened = listenedSeconds(for: session)
            guard listened > 0 else { return nil }
            return (session.podcastName ?? "Unknown Podcast", listened)
        }, by: \.0)
        .map { name, values in
            PodcastRollup(podcastName: name, totalSeconds: values.reduce(0) { $0 + $1.1 })
        }
        .sorted { $0.totalSeconds > $1.totalSeconds }
    }

    private var recentSessions: [PlaySession] {
        filteredSessions
    }

    private var filteredListeningStats: [ListeningStat] {
        listeningStats.filter { stat in
            selectedPodcastFeedString == nil || stat.podcastFeed?.absoluteString == selectedPodcastFeedString
        }
    }

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

    private var weekdayTotals: [WeekdayListeningTotal] {
        let totals: [Int: Double]
        if !filteredListeningStats.isEmpty {
            totals = Dictionary(grouping: filteredListeningStats.compactMap { stat -> (Int, Double)? in
                guard let startOfHour = stat.startOfHour, let totalSeconds = stat.totalSeconds, totalSeconds > 0 else { return nil }
                let weekday = (Calendar.current.component(.weekday, from: startOfHour) - 1)
                return (weekday, totalSeconds)
            }, by: \.0).mapValues { values in
                values.reduce(0) { $0 + $1.1 }
            }
        } else {
            totals = Dictionary(grouping: filteredSessions.compactMap { session -> (Int, Double)? in
                guard let startTime = session.startTime else { return nil }
                let totalSeconds = listenedSeconds(for: session)
                guard totalSeconds > 0 else { return nil }
                let weekday = (Calendar.current.component(.weekday, from: startTime) - 1)
                return (weekday, totalSeconds)
            }, by: \.0).mapValues { values in
                values.reduce(0) { $0 + $1.1 }
            }
        }

        return weekdayOrder.enumerated().map { index, weekday in
            WeekdayListeningTotal(
                weekday: weekday,
                label: weekdayLabels[index],
                totalSeconds: totals[weekday] ?? 0
            )
        }
    }

    private var habitHeatMapCells: [ListeningHabitCell] {
        let totals: [String: Double]
        if !filteredListeningStats.isEmpty {
            totals = Dictionary(grouping: filteredListeningStats.compactMap { stat -> (String, Double)? in
                guard let startOfHour = stat.startOfHour, let totalSeconds = stat.totalSeconds, totalSeconds > 0 else { return nil }
                let weekday = Calendar.current.component(.weekday, from: startOfHour) - 1
                let hour = Calendar.current.component(.hour, from: startOfHour)
                return ("\(weekday)-\(hour)", totalSeconds)
            }, by: \.0).mapValues { values in
                values.reduce(0) { $0 + $1.1 }
            }
        } else {
            totals = Dictionary(grouping: filteredSessions.compactMap { session -> (String, Double)? in
                guard let startTime = session.startTime else { return nil }
                let totalSeconds = listenedSeconds(for: session)
                guard totalSeconds > 0 else { return nil }
                let weekday = Calendar.current.component(.weekday, from: startTime) - 1
                let hour = Calendar.current.component(.hour, from: startTime)
                return ("\(weekday)-\(hour)", totalSeconds)
            }, by: \.0).mapValues { values in
                values.reduce(0) { $0 + $1.1 }
            }
        }

        return weekdayOrder.flatMap { weekday in
            (0..<24).map { hour in
                let key = "\(weekday)-\(hour)"
                return ListeningHabitCell(weekday: weekday, hour: hour, totalSeconds: totals[key] ?? 0)
            }
        }
    }

    private var habitHeatMapMaxSeconds: Double {
        max(habitHeatMapCells.map(\.totalSeconds).max() ?? 0, 1)
    }

    private var shouldRebuildAnalytics: Bool {
        !hasTriggeredRebuild && summaries.isEmpty && !sessions.isEmpty
    }

    private func rebuildAnalyticsIfNeeded() {
        guard shouldRebuildAnalytics else { return }
        hasTriggeredRebuild = true
        let container = modelContext.container
        Task {
            await PlaySessionTrackerActor(modelContainer: container).rebuildListeningStats()
        }
    }

    private let summaryGrid = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

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
                        value: formatDuration(totalListeningSeconds),
                        detail: "\(groupedTotals.count) \(selectedPeriod.title.lowercased()) tracked"
                    )
                    summaryCard(
                        title: "Average \(selectedPeriod.title.dropLast())",
                        value: formatDuration(averagePeriodSeconds),
                        detail: selectedPodcastTitle
                    )
                    summaryCard(
                        title: "Best \(selectedPeriod.title.dropLast())",
                        value: bestPeriod.map { formatDuration($0.totalSeconds) } ?? "None",
                        detail: bestPeriod.map { periodLabel(for: $0.start, period: selectedPeriod) } ?? "No data yet"
                    )
                    summaryCard(
                        title: "Recent Sessions",
                        value: "\(recentSessions.prefix(30).count)",
                        detail: summaryTotals.isEmpty ? "Showing live data from raw sessions" : "Detailed history kept for the newest sessions"
                    )
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            if !chartPoints.isEmpty {
                Section("Listening Trend") {
                    Text("Y-axis: listening time per \(selectedPeriod.title.dropLast().lowercased()).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Chart(chartPoints) { point in
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

            if !weekdayTotals.allSatisfy({ $0.totalSeconds == 0 }) {
                Section("Listening Habits") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("When you usually listen")
                            .font(.headline)
                        Text("Weekday totals and an hour-by-weekday heat map based on your listening history.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Chart(weekdayTotals) { item in
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

            if selectedPodcastFeedString == nil && !podcastBreakdown.isEmpty {
                Section("Top Podcasts") {
                    ForEach(podcastBreakdown.prefix(8)) { rollup in
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
                                total: podcastBreakdown.first?.totalSeconds ?? rollup.totalSeconds
                            )
                            .frame(width: 100)
                        }
                    }
                }
            }

            Section("\(selectedPeriod.title) History") {
                if groupedTotals.isEmpty {
                    ContentUnavailableView(
                        "No Listening History",
                        systemImage: "chart.bar.xaxis",
                        description: Text("Start listening to see your summarized playback history here.")
                    )
                } else {
                    ForEach(groupedTotals) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(periodLabel(for: item.start, period: selectedPeriod))
                                    .font(.headline)
                                Text(selectedPodcastTitle)
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
                ForEach(recentSessions.prefix(20)) { session in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.episode?.title ?? "Unknown Episode")
                                    .font(.headline)
                                Text(session.podcastName ?? "Unknown Podcast")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(formatDuration(listenedSeconds(for: session)))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                        }

                        HStack {
                            Text(session.startTime ?? Date(), format: .dateTime.month().day().hour().minute())
                            Spacer()
                            Text(session.endedCleanly == true ? "Ended cleanly" : "Recovered / interrupted")
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
        .task {
            rebuildAnalyticsIfNeeded()
        }
        .onChange(of: sessions.count) { _, _ in
            rebuildAnalyticsIfNeeded()
        }
        .onChange(of: summaries.count) { _, _ in
            if summaries.isEmpty {
                rebuildAnalyticsIfNeeded()
            }
        }
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
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
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
                            let seconds = habitHeatMapCells.first(where: { $0.weekday == weekday && $0.hour == hour })?.totalSeconds ?? 0
                            RoundedRectangle(cornerRadius: 3)
                                .fill(heatColor(for: seconds))
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
                    heatColor(for: habitHeatMapMaxSeconds * 0.35),
                    heatColor(for: habitHeatMapMaxSeconds)
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
        let intensity = min(max(seconds / habitHeatMapMaxSeconds, 0), 1)
        return Color.accentColor.opacity(0.12 + intensity * 0.88)
    }
}

#Preview {
    NavigationStack {
        PlaySessionDebugView()
    }
}
