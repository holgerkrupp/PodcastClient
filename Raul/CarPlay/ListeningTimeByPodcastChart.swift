//  ListeningTimeByPodcastChart.swift
//  Raul
//
//  Shows a bar chart of total listening time per podcast using Swift Charts.

import SwiftUI
import Charts
import SwiftData

struct PodcastListeningStat: Identifiable {
    var id: String { podcastName }
    let podcastName: String
    let totalSeconds: Double
}

struct ListeningTimeByPodcastChart: View {
    @Environment(\.modelContext) private var modelContext
    @State private var weekStartDate: Date? = nil
    @State private var podcastStats: [PodcastListeningStat] = []
    @Query(sort: \ListeningStat.startOfHour, order: .reverse) var latestStat: [ListeningStat]

    private var sessionSignature: String {
        let latestStart = latestStat.first?.startOfHour?.timeIntervalSinceReferenceDate ?? 0
        let latestTotal = latestStat.first?.totalSeconds ?? 0
        let weekKey = weekStartDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(latestStart)-\(latestTotal)-\(weekKey)"
    }

    private func recalculateStats() async {
        let weekStart = weekStartDate
        let weekEnd = weekStart.flatMap { Calendar.current.date(byAdding: .day, value: 7, to: $0) }

        let predicate: Predicate<ListeningStat>?
        if let weekStart, let weekEnd {
            predicate = #Predicate<ListeningStat> { stat in
                stat.startOfHour != nil
                && stat.startOfHour! >= weekStart
                && stat.startOfHour! < weekEnd
            }
        } else {
            predicate = nil
        }

        let descriptor = FetchDescriptor<ListeningStat>(predicate: predicate, sortBy: [SortDescriptor(\.startOfHour, order: .forward)])
        let fetched: [ListeningStat]
        do {
            fetched = try modelContext.fetch(descriptor)
        } catch {
            return
        }

        var totals: [String: Double] = [:]

        for stat in fetched {
            guard let name = stat.podcastName, let seconds = stat.totalSeconds, seconds > 0 else { continue }
            totals[name, default: 0] += seconds
        }

        podcastStats = totals.map { PodcastListeningStat(podcastName: $0.key, totalSeconds: $0.value) }
            .sorted { $0.totalSeconds > $1.totalSeconds }
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Total Listening Time per Podcast")
                .font(.headline)
                .padding(.top)
            
            // Week selector
            HStack {
                Button(action: {
                    if let start = weekStartDate {
                        weekStartDate = Calendar.current.date(byAdding: .day, value: -7, to: start)
                    } else {
                        // Go to most recent full week
                        weekStartDate = Calendar.current.date(from: Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))
                    }
                }) {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Previous week")
                .accessibilityHint("Shows listening stats for the previous week")
                Button("Summary") {
                    weekStartDate = nil
                }
                .font(.caption)
                .foregroundStyle(weekStartDate == nil ? .primary : .secondary)
                .accessibilityHint("Shows listening stats aggregated across all weeks")
                Button(action: {
                    if let start = weekStartDate {
                        weekStartDate = Calendar.current.date(byAdding: .day, value: 7, to: start)
                    }
                }) {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("Next week")
                .accessibilityHint("Shows listening stats for the following week")

            }
            if let weekStart = weekStartDate {
                let weekEnd = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
                Text("\(weekStart.formatted(date: .abbreviated, time: .omitted)) – \(weekEnd.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .padding(.leading)
            }
            
            if podcastStats.isEmpty {
                Text("No listening data yet.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                Chart(podcastStats) { stat in
                    SectorMark(
                        angle: .value("Listening Time", stat.totalSeconds),
                        angularInset: 1
                    )
                    .foregroundStyle(by: .value("Podcast", "\(stat.podcastName) (\(formatTime(stat.totalSeconds)))"))
                }
            }
            Spacer()
        }
        .task(id: sessionSignature) {
            await recalculateStats()
        }
        .padding()
    }

    func formatTime(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(mins)m"
        } else {
            return "\(mins)m"
        }
    }
}

#Preview {
    ListeningTimeByPodcastChart()
}
