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
    @Query(sort: \PlaySession.startTime, order: .reverse) var sessions: [PlaySession]
    
    // Compute total seconds listened per podcast
    var podcastStats: [PodcastListeningStat] {
        let grouped = Dictionary(grouping: sessions.compactMap { session -> (String, Double)? in
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
            if podcastStats.isEmpty {
                Text("No listening data yet.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                Chart(podcastStats) { stat in
                    BarMark(
                        x: .value("Podcast", stat.podcastName),
                        y: .value("Minutes", stat.totalSeconds / 60)
                    )
                    .annotation(position: .top) {
                        Text(formatTime(stat.totalSeconds))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 280)
                .padding(.horizontal)
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
