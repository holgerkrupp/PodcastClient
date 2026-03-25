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
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ListeningStat.startOfHour, order: .reverse) var latestStat: [ListeningStat]
    @Query var podcasts: [Podcast]
    @State private var selectedPodcastFeed: URL? = nil
    @State private var weekStartDate: Date? = nil
    @State private var blocksByHour: [HourOfWeek: Double] = [:]
    @State private var maxSeconds: Double = 1

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

    private var sessionSignature: String {
        let latestStart = latestStat.first?.startOfHour?.timeIntervalSinceReferenceDate ?? 0
        let latestTotal = latestStat.first?.totalSeconds ?? 0
        let weekKey = weekStartDate?.timeIntervalSinceReferenceDate ?? 0
        let feedKey = selectedPodcastFeed?.absoluteString ?? ""
        return "\(latestStart)-\(latestTotal)-\(weekKey)-\(feedKey)"
    }

    private func recalculateBlocks() async {
        let selectedFeed = selectedPodcastFeed
        let weekStart = weekStartDate
        let weekEnd = weekStart.flatMap { Calendar.current.date(byAdding: .day, value: 7, to: $0) }

        let predicate: Predicate<ListeningStat>?
        if let weekStart, let weekEnd, let selectedFeed {
            predicate = #Predicate<ListeningStat> { stat in
                stat.startOfHour != nil
                && stat.startOfHour! >= weekStart
                && stat.startOfHour! < weekEnd
                && stat.podcastFeed == selectedFeed
            }
        } else if let weekStart, let weekEnd {
            predicate = #Predicate<ListeningStat> { stat in
                stat.startOfHour != nil
                && stat.startOfHour! >= weekStart
                && stat.startOfHour! < weekEnd
            }
        } else if let selectedFeed {
            predicate = #Predicate<ListeningStat> { stat in
                stat.podcastFeed == selectedFeed
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

        var totals: [HourOfWeek: Double] = [:]
        let calendar = Calendar.current

        for stat in fetched {
            guard let startOfHour = stat.startOfHour, let seconds = stat.totalSeconds, seconds > 0 else { continue }
            let comps = calendar.dateComponents([.weekday, .hour], from: startOfHour)
            let weekday = ((comps.weekday ?? 1) - 1)
            let hour = comps.hour ?? 0
            let blockKey = HourOfWeek(weekday: weekday, hour: hour)
            totals[blockKey, default: 0] += seconds
        }

        blocksByHour = totals
        maxSeconds = totals.values.max() ?? 1
    }

    var body: some View {
        VStack(spacing: 25) {
            // Podcast Picker
            Picker("Podcast", selection: $selectedPodcastFeed) {
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
                
            }
            if let weekStart = weekStartDate {
                let weekEnd = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
                Text("\(weekStart.formatted(date: .abbreviated, time: .omitted)) – \(weekEnd.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .padding(.leading)
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
                                let seconds = blocksByHour[key] ?? 0
                                let percent = min(1.0, seconds / maxSeconds)
                                Rectangle()
                                    .fill(Color.red.opacity(percent * 0.8 + 0.1))
                                    .frame(width: blockWidth, height: blockHeight)
                                /*
                                    .overlay(
                                        percent > 0.55 ? Text("\(Int(seconds / 60))m")
                                            .font(.caption2)
                                            .foregroundColor(.white)
                                        : nil
                                    )
                                */
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
        .task(id: sessionSignature) {
            await recalculateBlocks()
        }
        .navigationTitle(weekStartDate == nil ? "Weekly Listening Heat Map" : {
            let weekEnd = weekStartDate.flatMap { Calendar.current.date(byAdding: .day, value: 6, to: $0) } ?? Date()
            return "Heat Map (\(weekStartDate?.formatted(date: .abbreviated, time: .omitted) ?? "") – \(weekEnd.formatted(date: .abbreviated, time: .omitted)))"
        }())
    }
}

#Preview {
    WeekListeningHeatMapView()
}
