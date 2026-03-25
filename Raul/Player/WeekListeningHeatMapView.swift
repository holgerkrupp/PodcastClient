//  WeekListeningHeatMapView.swift
//  Raul
//
//  A SwiftUI heatmap showing the user's listening time distribution by hour and day of week.

import SwiftUI
import SwiftData

private struct WeekHeatMapSnapshot {
    static let empty = WeekHeatMapSnapshot(secondsByWeekday: [:], maxSeconds: 1)

    let secondsByWeekday: [Int: [Double]]
    let maxSeconds: Double

    func seconds(weekday: Int, hour: Int) -> Double {
        guard let hours = secondsByWeekday[weekday], hours.indices.contains(hour) else { return 0 }
        return hours[hour]
    }
}

struct WeekListeningHeatMapView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Podcast.title) private var podcasts: [Podcast]

    @State private var selectedPodcastFeed: URL? = nil
    @State private var weekStartDate: Date? = nil
    @State private var heatMap = WeekHeatMapSnapshot.empty

    private let hours = Array(0..<24)

    private var rotatedWeekdays: [String] {
        let symbols = Calendar.current.shortWeekdaySymbols
        let first = Calendar.current.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var weekdayIndexOrder: [Int] {
        let first = Calendar.current.firstWeekday - 1
        return (0..<7).map { (first + $0) % 7 }
    }

    private var weekdayColumns: [(weekday: Int, label: String)] {
        Array(zip(weekdayIndexOrder, rotatedWeekdays))
    }

    private var refreshSignature: String {
        "\(selectedPodcastFeed?.absoluteString ?? "all")|\(weekStartDate?.timeIntervalSinceReferenceDate ?? 0)"
    }

    var body: some View {
        VStack(spacing: 25) {
            Picker("Podcast", selection: $selectedPodcastFeed) {
                Text("All Podcasts").tag(URL?.none)
                ForEach(podcasts, id: \.id) { podcast in
                    if let feed = podcast.feed {
                        Text(podcast.title).tag(Optional(feed))
                    }
                }
            }
            .pickerStyle(.menu)

            HStack {
                Button(action: {
                    if let start = weekStartDate {
                        weekStartDate = Calendar.current.date(byAdding: .day, value: -7, to: start)
                    } else {
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
                .disabled(weekStartDate == nil)
            }

            if let weekStart = weekStartDate {
                let weekEnd = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
                Text("\(weekStart.formatted(date: .abbreviated, time: .omitted)) – \(weekEnd.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .padding(.leading)
            }

            GeometryReader { geo in
                let labelColumnWidth: CGFloat = 56
                let availableWidth = geo.size.width - labelColumnWidth
                let blockWidth = max(18, availableWidth / 7)
                let blockHeight = max(10, (geo.size.height - 18) / 24)

                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        Text("")
                            .font(.caption2)
                            .frame(width: labelColumnWidth, height: 18)
                        ForEach(hours, id: \.self) { hour in
                            Text(String(format: "%02d:00", hour))
                                .monospacedDigit()
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: labelColumnWidth, height: blockHeight, alignment: .trailing)
                        }
                    }

                    ForEach(weekdayColumns, id: \.weekday) { column in
                        VStack(spacing: 0) {
                            Text(column.label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: blockWidth, height: 18)

                            ForEach(hours, id: \.self) { hour in
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(heatColor(for: heatMap.seconds(weekday: column.weekday, hour: hour)))
                                    .frame(width: blockWidth, height: blockHeight)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 420)

            HStack(spacing: 10) {
                Text("Less")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                LinearGradient(colors: [
                    heatColor(for: 0),
                    heatColor(for: heatMap.maxSeconds * 0.35),
                    heatColor(for: heatMap.maxSeconds)
                ], startPoint: .leading, endPoint: .trailing)
                .frame(height: 10)
                .clipShape(Capsule())
                Text("More")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: refreshSignature) {
            await recalculateBlocks()
        }
        .navigationTitle(weekStartDate == nil ? "Weekly Listening Heat Map" : {
            let weekEnd = weekStartDate.flatMap { Calendar.current.date(byAdding: .day, value: 6, to: $0) } ?? Date()
            return "Heat Map (\(weekStartDate?.formatted(date: .abbreviated, time: .omitted) ?? "") – \(weekEnd.formatted(date: .abbreviated, time: .omitted)))"
        }())
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

        let descriptor = FetchDescriptor<ListeningStat>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startOfHour, order: .forward)]
        )

        let fetched: [ListeningStat]
        do {
            fetched = try modelContext.fetch(descriptor)
        } catch {
            return
        }

        var secondsByWeekday = Dictionary(uniqueKeysWithValues: weekdayIndexOrder.map { ($0, Array(repeating: 0.0, count: 24)) })
        let calendar = Calendar.current

        for stat in fetched {
            guard let startOfHour = stat.startOfHour, let seconds = stat.totalSeconds, seconds > 0 else { continue }
            let weekday = calendar.component(.weekday, from: startOfHour) - 1
            let hour = calendar.component(.hour, from: startOfHour)
            var hours = secondsByWeekday[weekday] ?? Array(repeating: 0, count: 24)
            if hours.indices.contains(hour) {
                hours[hour] += seconds
            }
            secondsByWeekday[weekday] = hours
        }

        heatMap = WeekHeatMapSnapshot(
            secondsByWeekday: secondsByWeekday,
            maxSeconds: max(secondsByWeekday.values.compactMap { $0.max() }.max() ?? 0, 1)
        )
    }

    private func heatColor(for seconds: Double) -> Color {
        let intensity = min(max(seconds / heatMap.maxSeconds, 0), 1)
        return Color.accentColor.opacity(0.12 + intensity * 0.88)
    }
}

#Preview {
    WeekListeningHeatMapView()
}
