//  WeekListeningHeatMapView.swift
//  Raul
//
//  A SwiftUI heatmap showing the user's listening time distribution by hour and day of week.

import SwiftUI
import SwiftData

struct HourOfWeek: Hashable, Identifiable {
    // 0 = Sunday, 1 = Monday, ... 6 = Saturday
    let weekday: Int
    let hour: Int
    var id: String { "\(weekday)-\(hour)" }
}

struct ListeningBlock: Identifiable {
    let id: HourOfWeek
    let totalSeconds: Double
}

struct WeekListeningHeatMapView: View {
    @Query var sessions: [PlaySession]
    @Query var podcasts: [Podcast]
    @State private var selectedPodcastID: UUID? = nil
    @State private var weekStartDate: Date? = nil

    var filteredSessions: [PlaySession] {
        sessions.filter { session in
            // Podcast filter
            let podcastOK = selectedPodcastID == nil || session.episode?.podcast?.id == selectedPodcastID
            // Week filter
            guard let startDate = weekStartDate else { return podcastOK }
            guard let sessionStart = session.startTime else { return false }
            let calendar = Calendar.current
            guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: startDate) else { return false }
            return podcastOK && sessionStart >= startDate && sessionStart < weekEnd
        }
    }

    let hours = Array(0..<24)

    var rotatedWeekdays: [String] {
        let symbols = Calendar.current.shortWeekdaySymbols
        let first = Calendar.current.firstWeekday - 1 // 0-indexed
        return Array(symbols[first...] + symbols[..<first])
    }
    var weekdayIndexOrder: [Int] {
        let first = Calendar.current.firstWeekday - 1
        return (0..<7).map { (first + $0) % 7 }
    }

    // Precompute the heat map blocks
    var blocks: [ListeningBlock] {
        var result: [HourOfWeek: Double] = [:]
        for session in filteredSessions {
            guard let start = session.startTime, let end = session.endTime, end > start else { continue }
            let calendar = Calendar.current
            var cursor = start
            while cursor < end {
                let nextHour = calendar.date(byAdding: .hour, value: 1, to: cursor) ?? end
                let blockEnd = min(nextHour, end)
                let comps = calendar.dateComponents([.weekday, .hour], from: cursor)
                let weekday = ((comps.weekday ?? 1) - 1) // 0 = Sunday
                let hour = comps.hour ?? 0
                let blockKey = HourOfWeek(weekday: weekday, hour: hour)
                let seconds = blockEnd.timeIntervalSince(cursor)
                result[blockKey, default: 0] += seconds
                cursor = blockEnd
            }
        }
        return result.map { ListeningBlock(id: $0.key, totalSeconds: $0.value) }
    }

    var maxSeconds: Double {
        blocks.map { $0.totalSeconds }.max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Podcast Picker
            Picker("Podcast", selection: $selectedPodcastID) {
                Text("All Podcasts").tag(UUID?.none)
                ForEach(podcasts, id: \.id) { podcast in
                    Text(podcast.title).tag(Optional(podcast.id))
                }
            }
            .pickerStyle(.menu)

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
                if let weekStart = weekStartDate {
                    let weekEnd = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
                    Text("\(weekStart.formatted(date: .abbreviated, time: .omitted)) – \(weekEnd.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .padding(.leading)
                }
            }

            GeometryReader { geo in
                let labelColumnWidth: CGFloat = 30
                let availableWidth = geo.size.width
                let blockWidth = (availableWidth - labelColumnWidth) / 8
                let blockHeight = (geo.size.height - labelColumnWidth) / 24

                HStack(spacing: 0) {
                    // Hour labels column
                    VStack(spacing: 0) {
                        ForEach(hours, id: \.self) { hour in
                            Text(String(format: "%02d:00", hour))
                                .monospacedDigit()
                                .font(.caption)
                                .frame(width: labelColumnWidth*2, height: blockHeight, alignment: .trailing)
                        }
                    }
                    // Days columns
                    ForEach(weekdayIndexOrder, id: \.self) { weekday in
                        VStack(spacing: 0) {
                            ForEach(hours, id: \.self) { hour in
                                let key = HourOfWeek(weekday: weekday, hour: hour)
                                let block = blocks.first(where: { $0.id == key })
                                let percent = min(1.0, (block?.totalSeconds ?? 0) / maxSeconds)
                                Rectangle()
                                    .fill(Color.red.opacity(percent * 0.8 + 0.1))
                                    .frame(width: blockWidth, height: blockHeight)
                                    .overlay(
                                        percent > 0.55 ? Text("\(Int((block?.totalSeconds ?? 0) / 60))m")
                                            .font(.caption2)
                                            .foregroundColor(.white)
                                        : nil
                                    )
                            }
                        }
                        .overlay(
                            Text(rotatedWeekdays[weekdayIndexOrder.firstIndex(of: weekday) ?? weekday])
                                .rotationEffect(.degrees(-45))
                                .font(.caption2)
                                .offset(y: -12)
                            , alignment: .top
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(weekStartDate == nil ? "Weekly Listening Heat Map" : {
            let weekEnd = weekStartDate.flatMap { Calendar.current.date(byAdding: .day, value: 6, to: $0) } ?? Date()
            return "Heat Map (\(weekStartDate?.formatted(date: .abbreviated, time: .omitted) ?? "") – \(weekEnd.formatted(date: .abbreviated, time: .omitted)))"
        }())
    }
}

#Preview {
    WeekListeningHeatMapView()
}
