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
    @State private var weekStartDate: Date? = nil
    @Query(sort: \PlaySession.startTime, order: .reverse) var sessions: [PlaySession]
    
    var filteredSessions: [PlaySession] {
        guard let startDate = weekStartDate else { return sessions }
        let calendar = Calendar.current
        guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: startDate) else { return sessions }
        return sessions.filter { session in
            guard let sessionStart = session.startTime else { return false }
            return sessionStart >= startDate && sessionStart < weekEnd
        }
    }
    
    // Compute total seconds listened per podcast
    var podcastStats: [PodcastListeningStat] {
        let grouped = Dictionary(grouping: filteredSessions.compactMap { session -> (String, Double)? in
            guard
                let name = session.podcastName,
                let start = session.startTime,
                let end = session.endTime,
                end > start
            else { return nil }
            return (name, end.timeIntervalSince(start))
        }) { $0.0 }
        return grouped.map { (podcast, tuples) in
            PodcastListeningStat(podcastName: podcast, totalSeconds: tuples.map { $0.1 }.reduce(0, +))
        }
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
                Button("Summary") {
                    weekStartDate = nil
                }
                .font(.caption)
                .foregroundStyle(weekStartDate == nil ? .primary : .secondary)
                Button(action: {
                    if let start = weekStartDate {
                        weekStartDate = Calendar.current.date(byAdding: .day, value: 7, to: start)
                    }
                }) {
                    Image(systemName: "chevron.right")
                }

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
