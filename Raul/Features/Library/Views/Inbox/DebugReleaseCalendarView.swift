#if DEBUG
import SwiftUI
import SwiftData

private struct PredictedRelease: Identifiable {
    let podcast: Podcast
    let date: Date

    var id: PersistentIdentifier { podcast.persistentModelID }
}

private struct PredictedReleaseDay: Identifiable {
    let date: Date
    let releases: [PredictedRelease]

    var id: Date { date }
}

private enum ReleaseCalendarPresentation: String, CaseIterable, Identifiable {
    case month
    case list

    var id: String { rawValue }
}

struct DebugReleaseCalendarView: View {
    let podcasts: [Podcast]

    @Environment(\.dismiss) private var dismiss
    @State private var displayedMonth = Calendar.autoupdatingCurrent.startOfMonth(for: .now)
    @State private var selectedDate = Calendar.autoupdatingCurrent.startOfDay(for: .now)
    @State private var presentation: ReleaseCalendarPresentation = .month

    private var calendar: Calendar { .autoupdatingCurrent }

    private var releases: [PredictedRelease] {
        let today = calendar.startOfDay(for: .now)
        return podcasts.compactMap { podcast in
            guard podcast.metaData?.isSubscribed != false,
                  let date = podcast.metaData?.nextPredictedReleaseDate,
                  calendar.startOfDay(for: date) >= today else { return nil }
            return PredictedRelease(podcast: podcast, date: date)
        }
        .sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.podcast.title.localizedCaseInsensitiveCompare($1.podcast.title) == .orderedAscending
        }
    }

    private var selectedDayReleases: [PredictedRelease] {
        releases.filter { calendar.isDate($0.date, inSameDayAs: selectedDate) }
    }

    private var releaseDays: [PredictedReleaseDay] {
        Dictionary(grouping: releases) { calendar.startOfDay(for: $0.date) }
            .map { PredictedReleaseDay(date: $0.key, releases: $0.value) }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            presentationPicker
                .padding(.horizontal)
                .padding(.top, 12)

            switch presentation {
            case .month:
                monthHeader
                    .padding(.horizontal)
                    .padding(.top, 8)

                monthGrid
                    .padding(.horizontal, 12)
                    .padding(.top, 12)

                Divider().padding(.top, 8)
                selectedDayList
            case .list:
                predictedReleasesList
            }
        }
        .navigationTitle("Release prediction")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear(perform: selectNearestReleaseIfUseful)
        .onChange(of: displayedMonth) { _, month in
            guard calendar.isDate(selectedDate, equalTo: month, toGranularity: .month) else {
                selectedDate = month
                return
            }
        }
    }

    private var presentationPicker: some View {
        Picker("Calendar view", selection: $presentation) {
            Label("Month", systemImage: "calendar").tag(ReleaseCalendarPresentation.month)
            Label("List", systemImage: "list.bullet").tag(ReleaseCalendarPresentation.list)
        }
        .pickerStyle(.segmented)
        .accessibilityHint("Switches between the month calendar and a scrolling list of predicted releases")
    }

    private var selectedDayList: some View {
        List {
            Section {
                if selectedDayReleases.isEmpty {
                    ContentUnavailableView(
                        "No predicted releases",
                        systemImage: "calendar",
                        description: Text(
                            releases.isEmpty
                                ? "No future release predictions are available."
                                : "Choose a marked day to see its predicted podcast releases."
                        )
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(selectedDayReleases) { release in
                        navigableReleaseRow(release)
                    }
                }
            } header: {
                Text(selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    private var predictedReleasesList: some View {
        ScrollView {
            if releaseDays.isEmpty {
                ContentUnavailableView(
                    "No predicted releases",
                    systemImage: "calendar",
                    description: Text("Future release predictions will appear here when available.")
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(releaseDays) { day in
                        Section {
                            ForEach(day.releases) { release in
                                navigableReleaseRow(release)
                                if release.id != day.releases.last?.id {
                                    Divider().padding(.leading, 12)
                                }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("W\(calendar.component(.weekOfYear, from: day.date))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(.regularMaterial)
                        }
                    }
                }
            }
        }
    }

    private func navigableReleaseRow(_ release: PredictedRelease) -> some View {
        ZStack {
            HStack(spacing: 8) {
                PodcastRowView(podcast: release.podcast, density: .compact)
                Text(release.date, format: .dateTime.hour().minute())
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            NavigationLink(destination: PodcastDetailView(podcast: release.podcast)) {
                EmptyView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(0)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .accessibilityLabel("Open podcast \(release.podcast.title)")
        .accessibilityHint("Opens this podcast's details")
        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var monthHeader: some View {
        HStack {
            Button {
                moveMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Previous month")

            Spacer()
            Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()

            Button {
                moveMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Next month")
        }
    }

    private var monthGrid: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let firstWeekday = calendar.firstWeekday - 1
        let orderedSymbols = Array(symbols[firstWeekday...]) + Array(symbols[..<firstWeekday])
        let dates = monthDates

        return VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(Array(orderedSymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                ForEach(Array(dates.enumerated()), id: \.offset) { _, date in
                    if let date {
                        dayButton(date)
                    } else {
                        Color.clear.frame(height: 40)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func dayButton(_ date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let hasReleases = releases.contains { calendar.isDate($0.date, inSameDayAs: date) }

        return Button {
            selectedDate = date
        } label: {
            VStack(spacing: 2) {
                Text(date.formatted(.dateTime.day()))
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Circle()
                    .fill(hasReleases ? (isSelected ? Color.white : Color.accentColor) : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background {
                if isSelected {
                    Circle().fill(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityValue(hasReleases ? "Has predicted releases" : "No predicted releases")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var monthDates: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: displayedMonth),
              let dayRange = calendar.range(of: .day, in: .month, for: displayedMonth) else { return [] }
        let leadingEmptyDays = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        var dates = Array<Date?>(repeating: nil, count: leadingEmptyDays)
        for day in dayRange {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: interval.start) {
                dates.append(date)
            }
        }
        while dates.count.isMultiple(of: 7) == false { dates.append(nil) }
        return dates
    }

    private func moveMonth(by amount: Int) {
        guard let month = calendar.date(byAdding: .month, value: amount, to: displayedMonth) else { return }
        displayedMonth = calendar.startOfMonth(for: month)
    }

    private func selectNearestReleaseIfUseful() {
        guard let firstRelease = releases.first,
              selectedDayReleases.isEmpty else { return }
        selectedDate = calendar.startOfDay(for: firstRelease.date)
        displayedMonth = calendar.startOfMonth(for: firstRelease.date)
    }
}

private extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        dateInterval(of: .month, for: date)?.start ?? startOfDay(for: date)
    }
}
#endif
