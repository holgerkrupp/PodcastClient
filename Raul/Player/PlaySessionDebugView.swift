//  PlaySessionDebugView.swift
//  Raul
//
//  Shows all PlaySessions and their details for debugging purposes.

import SwiftUI
import SwiftData

struct PlaySessionDebugView: View {
    @Query(sort: \PlaySession.startTime, order: .reverse) var sessions: [PlaySession]

    var body: some View {
        NavigationStack {
            
            NavigationLink(destination: ListeningTimeByPodcastChart()) {
                HStack {
                    Text("Listening Time by Podcast")
                        .font(.headline)

                }
            }
            
            NavigationLink(destination: WeekListeningHeatMapView()) {
                HStack {
                    Text("Listening Heatmap")
                        .font(.headline)

                }
            }
            
            
            
            List(sessions) { session in
                Section(header: Text(session.episode?.title ?? "").font(.headline)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Started: \(session.startTime ?? Date(), style: .date) \(session.startTime ?? Date(), style: .time)")
                        if let endTime = session.endTime {
                            Text("Ended: \(endTime, style: .date) \(endTime, style: .time)")
                        } else {
                            Text("Incomplete session").foregroundColor(.red)
                        }
                        Text("Start Pos: \(formatTime(session.startPosition))  End Pos: \(formatTime(session.endPosition))")
                        Text("Device: \(session.deviceModel) / iOS \(session.osVersion)")
                        Text("App Version: \(session.appVersion)")
                        Text("Ended Cleanly: \(session.endedCleanly ?? false ? "Yes" : "No")")
                        if !(session.segments?.isEmpty ?? true) {
                            Text("Segments: \(session.segments?.count)")
                        }
                    }
                    if !(session.segments?.isEmpty ?? true) {
                        ForEach(session.segments ?? []) { seg in
                            HStack {
                                Text("▶️ Rate: \(seg.rate)x")
                                Text("from \(formatTime(seg.startPosition)) to \(formatTime(seg.endPosition))")
                                if let endTime = seg.endTime {
                                    Text("(\(endTime, style: .time))").font(.caption2)
                                }
                            }.font(.caption)
                        }
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: 0,
                                     leading: 0,
                                     bottom: 0,
                                     trailing: 0))
            }
            .navigationTitle("PlaySessions Debug")
            .listStyle(.plain)
        }
    }

    func formatTime(_ time: Double?) -> String {
        guard let time else { return "-" }
        let mins = Int(time) / 60
        let secs = Int(time) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

#Preview {
    PlaySessionDebugView()
}
