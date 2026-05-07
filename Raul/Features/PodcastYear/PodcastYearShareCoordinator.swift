import SwiftUI
import SwiftData
import UserNotifications

extension Notification.Name {
    static let podcastYearShareNotificationTapped = Notification.Name("podcastYearShareNotificationTapped")
}

struct PodcastYearShareRequest: Identifiable {
    let year: Int
    let periodStart: Date
    let periodEnd: Date
    let podcasts: [PodcastYearPodcast]

    var id: Int { year }

    var totalSeconds: Double {
        podcasts.reduce(0) { $0 + $1.totalSeconds }
    }
}

struct PodcastYearPodcast: Identifiable {
    let rank: Int
    let title: String
    let totalSeconds: Double
    let coverURL: URL?

    var id: Int { rank }
}

private struct PodcastYearRollup {
    let key: String
    let feed: URL?
    let title: String
    let totalSeconds: Double
}

@MainActor
final class PodcastYearShareCoordinator: ObservableObject {
    @Published var sheetRequest: PodcastYearShareRequest?

    nonisolated static let notificationURL = URL(string: "upnext://podcast-year")!

    private let calendar: Calendar
    private let notificationIdentifier = "podcast-year-share-new-years-day"
    private let lastShownYearKey = "PodcastYearShare.lastShownYear"
    private let pendingNotificationTapKey = "PodcastYearShare.pendingNotificationTap"
    private let significantListeningThreshold: TimeInterval = 10 * 60 * 60

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    func evaluateAppLaunch(modelContext: ModelContext) async {
        await presentPendingNotificationTapIfNeeded(modelContext: modelContext)
        presentOnNewYearsDayIfNeeded(modelContext: modelContext)
        await scheduleNextNotificationIfNeeded(modelContext: modelContext)
    }

    func evaluateAppBecameActive(modelContext: ModelContext) async {
        await presentPendingNotificationTapIfNeeded(modelContext: modelContext)
        presentOnNewYearsDayIfNeeded(modelContext: modelContext)
        await scheduleNextNotificationIfNeeded(modelContext: modelContext)
    }

    func handleOpenURL(_ url: URL, modelContext: ModelContext) async -> Bool {
        guard Self.isPodcastYearURL(url) else { return false }
        presentPastYearIfNeeded(modelContext: modelContext, markAsShown: true)
        await scheduleNextNotificationIfNeeded(modelContext: modelContext)
        return true
    }

    func handleNotificationTap(modelContext: ModelContext) async {
        UserDefaults.standard.set(true, forKey: pendingNotificationTapKey)
        await presentPendingNotificationTapIfNeeded(modelContext: modelContext)
    }

    @discardableResult
    func presentDebugSheetNow(modelContext: ModelContext) -> Bool {
        for year in debugCandidateYears() {
            if let request = makeRequest(for: year, modelContext: modelContext) {
                sheetRequest = request
                return true
            }
        }

        return false
    }

    func debugAvailabilityReport(modelContext: ModelContext) -> String {
        var lines = [
            "There is no yearly listening history with more than 10 hours yet.",
            "",
            "Debug totals seen by Podcast Year:"
        ]

        for year in debugCandidateYears() {
            guard
                let periodStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                let periodEnd = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))
            else { continue }

            let hourlyTotal = fetchListeningStatRollups(
                periodStart: periodStart,
                periodEnd: periodEnd,
                modelContext: modelContext
            )
            .reduce(0) { $0 + $1.totalSeconds }

            let summaryTotals = PlaySessionSummaryPeriod.allCases.map { period in
                let total = fetchSummaryRollups(
                    period: period,
                    periodStart: periodStart,
                    modelContext: modelContext
                )
                .reduce(0) { $0 + $1.totalSeconds }
                return "\(period.rawValue): \(formatDebugHours(total))"
            }
            .joined(separator: ", ")

            let rawSessionTotal = fetchRawSessionTotal(
                periodStart: periodStart,
                periodEnd: periodEnd,
                modelContext: modelContext
            )

            lines.append("\(year): hourly \(formatDebugHours(hourlyTotal)), raw \(formatDebugHours(rawSessionTotal)), \(summaryTotals)")
        }

        return lines.joined(separator: "\n")
    }

    nonisolated static func isPodcastYearURL(_ url: URL) -> Bool {
        url.scheme == "upnext" && url.host == "podcast-year"
    }

    private func presentPendingNotificationTapIfNeeded(modelContext: ModelContext) async {
        guard UserDefaults.standard.bool(forKey: pendingNotificationTapKey) else { return }
        UserDefaults.standard.set(false, forKey: pendingNotificationTapKey)
        presentPastYearIfNeeded(modelContext: modelContext, markAsShown: true)
    }

    private func presentOnNewYearsDayIfNeeded(modelContext: ModelContext) {
        guard isNewYearsDay(Date()) else { return }
        presentPastYearIfNeeded(modelContext: modelContext, markAsShown: true)
    }

    private func presentPastYearIfNeeded(modelContext: ModelContext, markAsShown: Bool) {
        let year = wrappedYear(for: Date())
        guard lastShownYear != year else { return }
        guard let request = makeRequest(for: year, modelContext: modelContext) else { return }

        sheetRequest = request
        if markAsShown {
            lastShownYear = year
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        }
    }

    private func makeRequest(for year: Int, modelContext: ModelContext) -> PodcastYearShareRequest? {
        guard
            let periodStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
            let periodEnd = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))
        else { return nil }

        let statRollups = fetchListeningStatRollups(
            periodStart: periodStart,
            periodEnd: periodEnd,
            modelContext: modelContext
        )
        let summaryRollups = statRollups.isEmpty ? fetchSummaryRollups(
            periodStart: periodStart,
            modelContext: modelContext
        ) : []
        let rollups = statRollups.isEmpty ? summaryRollups : statRollups

        guard rollups.isEmpty == false else { return nil }
        let totalSeconds = rollups.reduce(0) { $0 + $1.totalSeconds }
        guard totalSeconds > significantListeningThreshold else { return nil }

        let podcasts = (try? modelContext.fetch(FetchDescriptor<Podcast>())) ?? []
        let coverURLsByFeed = Dictionary(
            grouping: podcasts.compactMap { podcast -> (String, URL?)? in
                guard let feed = podcast.feed?.absoluteString else { return nil }
                return (feed, podcast.imageURL)
            },
            by: \.0
        )
        .mapValues { $0.first?.1 ?? nil }

        let coverURLsByTitle = Dictionary(grouping: podcasts, by: \.title)
            .mapValues { $0.first?.imageURL }

        let requestPodcasts = rollups
            .sorted { $0.totalSeconds > $1.totalSeconds }
            .enumerated()
            .map { index, rollup in
                let feedString = rollup.feed?.absoluteString
                return PodcastYearPodcast(
                    rank: index + 1,
                    title: rollup.title,
                    totalSeconds: rollup.totalSeconds,
                    coverURL: feedString.flatMap { coverURLsByFeed[$0] } ?? coverURLsByTitle[rollup.title] ?? nil
                )
            }

        return PodcastYearShareRequest(
            year: year,
            periodStart: periodStart,
            periodEnd: periodEnd,
            podcasts: requestPodcasts
        )
    }

    private func scheduleNextNotificationIfNeeded(modelContext: ModelContext) async {
        let now = Date()
        guard let scheduled = nextNotificationDate(after: now) else { return }
        let wrappedYear = wrappedYear(for: scheduled)

        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        guard lastShownYear != wrappedYear else { return }
        guard makeRequest(for: wrappedYear, modelContext: modelContext) != nil else { return }

        let status = await notificationAuthorizationStatus()
        switch status {
        case .notDetermined:
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard granted else { return }
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            return
        @unknown default:
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Share your podcast year"
        content.body = "Your \(wrappedYear) podcast year is ready."
        content.sound = .default
        content.userInfo = [
            "url": Self.notificationURL.absoluteString,
            "wrappedYear": wrappedYear
        ]

        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: scheduled)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: trigger)

        try? await UNUserNotificationCenter.current().add(request)
    }

    private func nextNotificationDate(after now: Date) -> Date? {
        let currentYear = calendar.component(.year, from: now)
        let thisYearsNotification = calendar.date(from: DateComponents(year: currentYear, month: 1, day: 1, hour: 11))

        if let thisYearsNotification,
           now < thisYearsNotification,
           lastShownYear != currentYear - 1 {
            return thisYearsNotification
        }

        return calendar.date(from: DateComponents(year: currentYear + 1, month: 1, day: 1, hour: 11))
    }

    private func isNewYearsDay(_ date: Date) -> Bool {
        let components = calendar.dateComponents([.month, .day], from: date)
        return components.month == 1 && components.day == 1
    }

    private func wrappedYear(for date: Date) -> Int {
        calendar.component(.year, from: date) - 1
    }

    private func fetchListeningStatRollups(
        periodStart: Date,
        periodEnd: Date,
        modelContext: ModelContext
    ) -> [PodcastYearRollup] {
        let predicate = #Predicate<ListeningStat> { stat in
            stat.startOfHour != nil
            && stat.startOfHour! >= periodStart
            && stat.startOfHour! < periodEnd
        }
        let descriptor = FetchDescriptor<ListeningStat>(predicate: predicate)
        let stats = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { ($0.totalSeconds ?? 0) > 0 }

        return Dictionary(grouping: stats.compactMap { stat -> PodcastYearRollup? in
            let totalSeconds = stat.totalSeconds ?? 0
            guard totalSeconds > 0 else { return nil }
            let title = stat.podcastName ?? "Podcast"
            let key = stat.podcastFeed?.absoluteString ?? title
            return PodcastYearRollup(
                key: key,
                feed: stat.podcastFeed,
                title: title,
                totalSeconds: totalSeconds
            )
        }, by: \.key)
        .map { _, values in
            let first = values[0]
            return PodcastYearRollup(
                key: first.key,
                feed: first.feed,
                title: first.title,
                totalSeconds: values.reduce(0) { $0 + $1.totalSeconds }
            )
        }
    }

    private func fetchSummaryRollups(
        periodStart: Date,
        modelContext: ModelContext
    ) -> [PodcastYearRollup] {
        for period in [PlaySessionSummaryPeriod.year, .month, .week, .day] {
            let rollups = fetchSummaryRollups(
                period: period,
                periodStart: periodStart,
                modelContext: modelContext
            )
            if rollups.isEmpty == false {
                return rollups
            }
        }

        return []
    }

    private func fetchSummaryRollups(
        period: PlaySessionSummaryPeriod,
        periodStart: Date,
        modelContext: ModelContext
    ) -> [PodcastYearRollup] {
        guard let periodEnd = calendar.date(byAdding: .year, value: 1, to: periodStart) else {
            return []
        }

        let periodKind = period.rawValue
        let descriptor = FetchDescriptor<PlaySessionSummary>(
            predicate: #Predicate<PlaySessionSummary> { summary in
                summary.periodKind == periodKind
                && summary.periodStart != nil
                && summary.periodStart! >= periodStart
                && summary.periodStart! < periodEnd
            },
            sortBy: [SortDescriptor(\.periodStart, order: .reverse)]
        )
        let primary = (try? modelContext.fetch(descriptor)) ?? []
        let summaries = (primary.isEmpty ? fetchSummaryFallback(periodKind: periodKind, periodStart: periodStart, periodEnd: periodEnd, modelContext: modelContext) : primary)
            .filter { summary in
                guard
                    let summaryStart = summary.periodStart,
                    (summary.totalSeconds ?? 0) > 0
                else { return false }

                if period == .year {
                    return calendar.isDate(summaryStart, equalTo: periodStart, toGranularity: .day)
                }

                return true
            }

        return Dictionary(grouping: summaries.compactMap { summary -> PodcastYearRollup? in
            let totalSeconds = summary.totalSeconds ?? 0
            guard totalSeconds > 0 else { return nil }
            let title = summary.podcastName ?? "Podcast"
            let key = summary.podcastFeed?.absoluteString ?? title
            return PodcastYearRollup(
                key: key,
                feed: summary.podcastFeed,
                title: title,
                totalSeconds: totalSeconds
            )
        }, by: \.key)
        .map { _, values in
            let first = values[0]
            return PodcastYearRollup(
                key: first.key,
                feed: first.feed,
                title: first.title,
                totalSeconds: values.reduce(0) { $0 + $1.totalSeconds }
            )
        }
    }

    private func fetchSummaryFallback(
        periodKind: String,
        periodStart: Date,
        periodEnd: Date,
        modelContext: ModelContext
    ) -> [PlaySessionSummary] {
        let descriptor = FetchDescriptor<PlaySessionSummary>(
            sortBy: [SortDescriptor(\.periodStart, order: .reverse)]
        )
        let summaries = (try? modelContext.fetch(descriptor)) ?? []

        return summaries.filter { summary in
            guard
                summary.periodKind == periodKind,
                let summaryStart = summary.periodStart,
                summaryStart >= periodStart,
                summaryStart < periodEnd
            else { return false }

            return true
        }
    }

    private func fetchRawSessionTotal(
        periodStart: Date,
        periodEnd: Date,
        modelContext: ModelContext
    ) -> Double {
        let descriptor = FetchDescriptor<PlaySession>(
            predicate: #Predicate<PlaySession> { session in
                session.startTime != nil
                && session.startTime! >= periodStart
                && session.startTime! < periodEnd
            }
        )
        let sessions = (try? modelContext.fetch(descriptor)) ?? []

        return sessions.reduce(0) { total, session in
            guard let start = session.startTime else { return total }
            let end = session.endTime ?? start
            return total + max(0, end.timeIntervalSince(start))
        }
    }

    private func formatDebugHours(_ seconds: Double) -> String {
        let hours = seconds / 3600
        return String(format: "%.1fh", hours)
    }

    private func debugCandidateYears() -> [Int] {
        let currentYear = calendar.component(.year, from: Date())
        return (1...5).map { currentYear - $0 }
    }

    private var lastShownYear: Int? {
        get {
            let value = UserDefaults.standard.integer(forKey: lastShownYearKey)
            return value == 0 ? nil : value
        }
        set {
            UserDefaults.standard.set(newValue, forKey: lastShownYearKey)
        }
    }

    private func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }
}

struct PodcastYearShareSheet: View {
    let request: PodcastYearShareRequest

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PodcastYearPreviewImage(request: request)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Share your podcast year")
                            .font(.title2.bold())
                        Text("Your \(request.year) listening recap is ready. Open the share picture view to customize and export it.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink {
                        StatisticsView(
                            initialPeriod: .year,
                            initialPeriodStart: request.periodStart,
                            presentShareGalleryOnAppear: true
                        )
                    } label: {
                        Label("Open Share Pictures", systemImage: "photo.on.rectangle.angled")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
            .navigationTitle("Podcast Year")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct PodcastYearPreviewImage: View {
    let request: PodcastYearShareRequest

    private var topPodcasts: [PodcastYearPodcast] {
        Array(request.podcasts.prefix(9))
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.08, blue: 0.10),
                    Color(red: 0.08, green: 0.20, blue: 0.18),
                    Color(red: 0.56, green: 0.32, blue: 0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("My Podcasts")
                        .font(.system(size: 32, weight: .black, design: .rounded))
                    Text("\(request.year)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(topPodcasts) { podcast in
                        PodcastYearCover(url: podcast.coverURL)
                    }
                }

                HStack {
                    Text("Up Next")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Spacer()
                    Text(totalListeningLine)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .foregroundStyle(.white)
            .padding(24)
        }
        .aspectRatio(4 / 5, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var totalListeningLine: String {
        let hours = max(request.totalSeconds / 3600, 0)
        let formatter = NumberFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = hours < 10 ? 1 : 0
        let formattedHours = formatter.string(from: NSNumber(value: hours)) ?? "\(Int(hours.rounded()))"
        return "\(formattedHours) hours"
    }
}

private struct PodcastYearCover: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.95, green: 0.40, blue: 0.25),
                            Color(red: 0.12, green: 0.55, blue: 0.62)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "waveform")
                        .font(.title2.bold())
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
    }
}
