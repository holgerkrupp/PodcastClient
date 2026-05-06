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

@MainActor
final class PodcastYearShareCoordinator: ObservableObject {
    @Published var sheetRequest: PodcastYearShareRequest?

    nonisolated static let notificationURL = URL(string: "upnext://podcast-year")!

    private let calendar: Calendar
    private let notificationIdentifier = "podcast-year-share-new-years-day"
    private let lastShownYearKey = "PodcastYearShare.lastShownYear"
    private let pendingNotificationTapKey = "PodcastYearShare.pendingNotificationTap"

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    func evaluateAppLaunch(modelContext: ModelContext) async {
        await presentPendingNotificationTapIfNeeded(modelContext: modelContext)
        presentOnNewYearsDayIfNeeded(modelContext: modelContext)
        await scheduleNextNotificationIfNeeded()
    }

    func evaluateAppBecameActive(modelContext: ModelContext) async {
        await presentPendingNotificationTapIfNeeded(modelContext: modelContext)
        presentOnNewYearsDayIfNeeded(modelContext: modelContext)
        await scheduleNextNotificationIfNeeded()
    }

    func handleOpenURL(_ url: URL, modelContext: ModelContext) async -> Bool {
        guard Self.isPodcastYearURL(url) else { return false }
        presentPastYearIfNeeded(modelContext: modelContext, markAsShown: true)
        await scheduleNextNotificationIfNeeded()
        return true
    }

    func handleNotificationTap(modelContext: ModelContext) async {
        UserDefaults.standard.set(true, forKey: pendingNotificationTapKey)
        await presentPendingNotificationTapIfNeeded(modelContext: modelContext)
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

        let periodKind = PlaySessionSummaryPeriod.year.rawValue
        let summaryDescriptor = FetchDescriptor<PlaySessionSummary>(
            predicate: #Predicate<PlaySessionSummary> { summary in
                summary.periodKind == periodKind
            },
            sortBy: [SortDescriptor(\.totalSeconds, order: .reverse)]
        )
        let summaries = ((try? modelContext.fetch(summaryDescriptor)) ?? [])
            .filter { summary in
                guard
                    let summaryStart = summary.periodStart,
                    summary.podcastFeed != nil,
                    (summary.totalSeconds ?? 0) > 0
                else { return false }

                return calendar.isDate(summaryStart, equalTo: periodStart, toGranularity: .day)
            }

        guard summaries.isEmpty == false else { return nil }

        let podcasts = (try? modelContext.fetch(FetchDescriptor<Podcast>())) ?? []
        let coverURLsByFeed = Dictionary(
            grouping: podcasts.compactMap { podcast -> (String, URL?)? in
                guard let feed = podcast.feed?.absoluteString else { return nil }
                return (feed, podcast.imageURL)
            },
            by: \.0
        )
        .mapValues { $0.first?.1 ?? nil }

        let requestPodcasts = summaries
            .sorted { ($0.totalSeconds ?? 0) > ($1.totalSeconds ?? 0) }
            .enumerated()
            .map { index, summary in
                let feedString = summary.podcastFeed?.absoluteString
                return PodcastYearPodcast(
                    rank: index + 1,
                    title: summary.podcastName ?? "Podcast",
                    totalSeconds: summary.totalSeconds ?? 0,
                    coverURL: feedString.flatMap { coverURLsByFeed[$0] } ?? nil
                )
            }

        return PodcastYearShareRequest(
            year: year,
            periodStart: periodStart,
            periodEnd: periodEnd,
            podcasts: requestPodcasts
        )
    }

    private func scheduleNextNotificationIfNeeded() async {
        let now = Date()
        guard let scheduled = nextNotificationDate(after: now) else { return }
        let wrappedYear = wrappedYear(for: scheduled)

        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        guard lastShownYear != wrappedYear else { return }

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
                        PlaySessionDebugView(
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
