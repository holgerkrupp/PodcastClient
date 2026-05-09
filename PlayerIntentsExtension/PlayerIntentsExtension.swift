//
//  PlayerIntentsExtension.swift
//  PlayerIntentsExtension
//
//  Created by Holger Krupp on 20.06.25.
//

import AppIntents
import Foundation
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PlayerIntentsExtension: AppIntent {
    static var title: LocalizedStringResource { "PlayerIntentsExtension" }
    
    func perform() async throws -> some IntentResult {
        return .result()
    }
}


struct ResumePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Playback"
   
    func perform() async throws -> some IntentResult {
        await Player.shared.play()
        return .result()
    }
}

struct BookmarkCurrentPlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Bookmark This"
    static let description = IntentDescription("Create a bookmark at the current playback position.")
    
    func perform() async throws -> some IntentResult {
        await Player.shared.createBookmark()
        return .result()
    }
}

struct PausePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Playback"
    static let description = IntentDescription("Pause the current episode.")

    func perform() async throws -> some IntentResult {
        await Player.shared.pause()
        return .result()
    }
}

struct SkipForwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Forward"
    static let description = IntentDescription("Skip forward by your configured duration.")

    func perform() async throws -> some IntentResult {
        await Player.shared.skipforward()
        return .result()
    }
}

struct SkipBackwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Backward"
    static let description = IntentDescription("Skip backward by your configured duration.")

    func perform() async throws -> some IntentResult {
        await Player.shared.skipback()
        return .result()
    }
}

struct PlayFirstUpNextIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Up Next"
    static let description = IntentDescription("Start playback with the first episode in your Up Next queue.")

    func perform() async throws -> some IntentResult {
        guard let playlistActor = await Player.shared.playlistActor else {
            return .result()
        }

        let urls = (try? await playlistActor.orderedEpisodeURLs()) ?? []
        guard let firstURL = urls.first else {
            return .result()
        }

        await Player.shared.playEpisode(firstURL, playDirectly: true)
        return .result()
    }
}

struct PlayNextUpNextIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Next Up Next Episode"
    static let description = IntentDescription("Play the next episode from your Up Next queue.")

    func perform() async throws -> some IntentResult {
        guard let playlistActor = await Player.shared.playlistActor else {
            return .result()
        }

        guard let nextURL = try? await playlistActor.nextEpisodeURL() else {
            return .result()
        }

        await Player.shared.playEpisode(nextURL, playDirectly: true)
        return .result()
    }
}

struct MoveCurrentEpisodeToEndIntent: AppIntent {
    static let title: LocalizedStringResource = "Move Current To End"
    static let description = IntentDescription("Move the current episode to the end of your Up Next queue.")

    func perform() async throws -> some IntentResult {
        guard let playlistActor = await Player.shared.playlistActor else {
            return .result()
        }
        guard let currentEpisodeURL = await Player.shared.currentEpisodeURL else {
            return .result()
        }

        try? await playlistActor.add(episodeURL: currentEpisodeURL, to: .end)
        return .result()
    }
}

struct RemoveCurrentFromUpNextIntent: AppIntent {
    static let title: LocalizedStringResource = "Remove Current From Up Next"
    static let description = IntentDescription("Remove the current episode from your Up Next queue.")

    func perform() async throws -> some IntentResult {
        guard let playlistActor = await Player.shared.playlistActor else {
            return .result()
        }
        guard let currentEpisodeURL = await Player.shared.currentEpisodeURL else {
            return .result()
        }

        try? await playlistActor.remove(episodeURL: currentEpisodeURL)
        return .result()
    }
}


struct BookmarkCurrentPlaybackShortcut: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: BookmarkCurrentPlaybackIntent(),
            phrases: ["Bookmark this in ${applicationName}", "Save a bookmark in ${applicationName}", "Bookmark the current position in ${applicationName}"],
            shortTitle: "Bookmark",
            systemImageName: "bookmark"
        )

        AppShortcut(
            intent: ResumePlaybackIntent(),
            phrases: ["Resume playback in ${applicationName}", "Play last episode in ${applicationName}"],
            shortTitle: "Resume",
            systemImageName: "play.circle"
        )

        AppShortcut(
            intent: PausePlaybackIntent(),
            phrases: ["Pause playback in ${applicationName}", "Pause ${applicationName}"],
            shortTitle: "Pause",
            systemImageName: "pause.circle"
        )

        AppShortcut(
            intent: SkipForwardIntent(),
            phrases: ["Skip forward in ${applicationName}", "Jump ahead in ${applicationName}"],
            shortTitle: "Forward",
            systemImageName: "arrow.forward.circle"
        )

        AppShortcut(
            intent: SkipBackwardIntent(),
            phrases: ["Skip back in ${applicationName}", "Jump back in ${applicationName}"],
            shortTitle: "Back",
            systemImageName: "arrow.backward.circle"
        )

        AppShortcut(
            intent: PlayFirstUpNextIntent(),
            phrases: ["Play Up Next in ${applicationName}", "Start Up Next in ${applicationName}"],
            shortTitle: "Play Up Next",
            systemImageName: "text.line.first.and.arrowtriangle.forward"
        )

        AppShortcut(
            intent: PlayNextUpNextIntent(),
            phrases: ["Play next episode in ${applicationName}", "Play what's next in ${applicationName}"],
            shortTitle: "Play Next",
            systemImageName: "forward.end"
        )

        AppShortcut(
            intent: MoveCurrentEpisodeToEndIntent(),
            phrases: ["Move this episode to the end in ${applicationName}", "Send current episode to the end in ${applicationName}"],
            shortTitle: "Move To End",
            systemImageName: "text.line.last.and.arrowtriangle.forward"
        )

        AppShortcut(
            intent: RemoveCurrentFromUpNextIntent(),
            phrases: ["Remove this from Up Next in ${applicationName}", "Remove current episode in ${applicationName}"],
            shortTitle: "Remove Current",
            systemImageName: "minus.circle"
        )

        AppShortcut(
            intent: GeneratePodcastShareImageIntent(),
            phrases: ["Generate podcast share image in ${applicationName}", "Create podcast stats image in ${applicationName}"],
            shortTitle: "Share Image",
            systemImageName: "photo.on.rectangle"
        )

    }
}

struct RefreshPodcastFeedsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Podcasts"
    static let description = IntentDescription("Check subscribed podcast feeds for new episodes.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await SubscriptionManager(modelContainer: ModelContainerManager.shared.container).bgupdateFeeds()
        return .result(dialog: "Podcast refresh started.")
    }
}

struct GeneratePodcastShareImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Generate Podcast Share Image"
    static let description = IntentDescription("Create a podcast listening statistics share image and return it as a PNG file.")
    static let openAppWhenRun = false

    @Parameter(title: "Period")
    var period: PodcastShareShortcutPeriod

    @Parameter(title: "When")
    var timing: PodcastShareShortcutTiming

    @Parameter(title: "Design")
    var design: PodcastShareShortcutDesign

    @Parameter(title: "Background")
    var background: PodcastShareShortcutBackground

    @Parameter(title: "Aspect Ratio")
    var aspectRatio: PodcastShareShortcutAspectRatio

    @Parameter(title: "Title", default: "My Podcasts")
    var title: String

    init() {
        period = .year
        timing = .previous
        design = .statistics
        background = .automatic
        aspectRatio = .portrait
        title = "My Podcasts"
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        let request = PodcastShareShortcutRequest(
            period: period.summaryPeriod,
            timing: timing,
            design: design.shareDesign,
            background: background,
            aspectRatio: aspectRatio,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "My Podcasts" : title
        )
        let file = try await PodcastShareShortcutRenderer().render(request: request)
        return .result(value: file, dialog: "Created podcast share image.")
    }
}

enum PodcastShareShortcutPeriod: String, AppEnum {
    case day
    case week
    case month
    case year

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Podcast Share Period")
    static let caseDisplayRepresentations: [PodcastShareShortcutPeriod: DisplayRepresentation] = [
        .day: "Day",
        .week: "Week",
        .month: "Month",
        .year: "Year"
    ]

    var summaryPeriod: PlaySessionSummaryPeriod {
        switch self {
        case .day:
            return .day
        case .week:
            return .week
        case .month:
            return .month
        case .year:
            return .year
        }
    }
}

enum PodcastShareShortcutTiming: String, AppEnum {
    case current
    case previous

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Podcast Share Timing")
    static let caseDisplayRepresentations: [PodcastShareShortcutTiming: DisplayRepresentation] = [
        .current: "Current Period",
        .previous: "Previous Period"
    ]
}

enum PodcastShareShortcutAspectRatio: String, AppEnum {
    case portrait
    case square
    case landscape

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Podcast Share Aspect Ratio")
    static let caseDisplayRepresentations: [PodcastShareShortcutAspectRatio: DisplayRepresentation] = [
        .portrait: "Portrait",
        .square: "Square",
        .landscape: "Landscape"
    ]

    var videoSize: CGSize {
        switch self {
        case .portrait:
            return CGSize(width: 720, height: 1280)
        case .square:
            return CGSize(width: 1080, height: 1080)
        case .landscape:
            return CGSize(width: 1920, height: 1080)
        }
    }
}

enum PodcastShareShortcutDesign: String, AppEnum {
    case podium
    case billboard
    case coverGrid
    case coverCollage
    case coverCloud
    case horizontalBars
    case pieChart
    case statistics

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Podcast Share Design")
    static let caseDisplayRepresentations: [PodcastShareShortcutDesign: DisplayRepresentation] = [
        .podium: "Podium Top 3",
        .billboard: "Billboard Top 10",
        .coverGrid: "Cover Grid",
        .coverCollage: "Cover Collage",
        .coverCloud: "Cover Cloud",
        .horizontalBars: "Playtime Bars",
        .pieChart: "Playtime Pie",
        .statistics: "Stats Wrapped"
    ]

    var shareDesign: TopPodcastShareDesign {
        switch self {
        case .podium:
            return .podium
        case .billboard:
            return .billboard
        case .coverGrid:
            return .coverGrid
        case .coverCollage:
            return .coverCollage
        case .coverCloud:
            return .coverCloud
        case .horizontalBars:
            return .horizontalBars
        case .pieChart:
            return .pieChart
        case .statistics:
            return .statistics
        }
    }
}

enum PodcastShareShortcutBackground: String, AppEnum {
    case automatic
    case current
    case stripes
    case rainbowGradient
    case white
    case black
    case january
    case february
    case march
    case april
    case may
    case june
    case july
    case august
    case september
    case october
    case november
    case december
    case newYear
    case carnival
    case christmas
    case easter
    case ramadan
    case eidAlFitr
    case hanukkah
    case holi
    case diwali
    case lunarNewYear
    case midsummer
    case halloween

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Podcast Share Background")
    static let caseDisplayRepresentations: [PodcastShareShortcutBackground: DisplayRepresentation] = [
        .automatic: "Automatic for Period",
        .current: "Boring",
        .stripes: "Rainbow",
        .rainbowGradient: "45 Gradient",
        .white: "White",
        .black: "Black",
        .january: "January",
        .february: "February",
        .march: "March",
        .april: "April",
        .may: "May",
        .june: "June",
        .july: "July",
        .august: "August",
        .september: "September",
        .october: "October",
        .november: "November",
        .december: "December",
        .newYear: "New Year",
        .carnival: "Carnival",
        .christmas: "Christmas",
        .easter: "Easter",
        .ramadan: "Ramadan",
        .eidAlFitr: "Eid al-Fitr",
        .hanukkah: "Hanukkah",
        .holi: "Holi",
        .diwali: "Diwali",
        .lunarNewYear: "Lunar New Year",
        .midsummer: "Midsummer",
        .halloween: "Halloween"
    ]

    var shareBackground: TopPodcastShareBackground {
        TopPodcastShareBackground(rawValue: rawValue) ?? .current
    }
}

private struct PodcastShareShortcutRequest {
    let period: PlaySessionSummaryPeriod
    let timing: PodcastShareShortcutTiming
    let design: TopPodcastShareDesign
    let background: PodcastShareShortcutBackground
    let aspectRatio: PodcastShareShortcutAspectRatio
    let title: String
}

@MainActor
private struct PodcastShareShortcutRenderer {
    private let calendar = Calendar.autoupdatingCurrent

    func render(request: PodcastShareShortcutRequest) async throws -> IntentFile {
        let context = ModelContext(ModelContainerManager.shared.container)
        let targetDate = targetDate(for: request.period, timing: request.timing)
        let start = periodStart(for: targetDate, period: request.period)
        let end = nextPeriodStart(from: start, period: request.period)
        let rollups = try podcastRollups(in: start..<end, period: request.period, context: context)
        guard rollups.count >= request.design.minimumItemCount else {
            throw PodcastShareShortcutError.noListeningHistory
        }

        let designRollups = request.design.usesAllItems ? rollups : Array(rollups.prefix(request.design.itemLimit))
        let items = await topPodcastShareItems(from: designRollups)
        let totalListeningSeconds = rollups.reduce(0) { $0 + $1.totalSeconds }
        let renderSize = TopPodcastShareAspect.renderSize(for: request.aspectRatio.videoSize)
        let background = resolvedBackground(request.background, for: start, period: request.period)
        let image = renderTopPodcastShareImage(
            items: items,
            design: request.design,
            periodLabel: sharePeriodLabel(for: start, period: request.period),
            dateRangeLabel: dateRangeLabel(start: start, end: end),
            totalListeningSeconds: totalListeningSeconds,
            shareTitle: request.title,
            background: background,
            renderSize: renderSize,
            stats: stats(
                rollups: rollups,
                start: start,
                end: end,
                period: request.period,
                context: context
            ),
            durationFormatter: formatDuration
        )

        guard let data = image?.pngData() else {
            throw PodcastShareShortcutError.renderFailed
        }

        let filename = "UpNext-\(request.design.title.filenameSafe)-\(UUID().uuidString).png"
        return IntentFile(data: data, filename: filename, type: .png)
    }

    private func podcastRollups(
        in range: Range<Date>,
        period: PlaySessionSummaryPeriod,
        context: ModelContext
    ) throws -> [PodcastRollup] {
        let podcasts = try context.fetch(FetchDescriptor<Podcast>())
        let coversByFeed = Dictionary(
            grouping: podcasts.compactMap { podcast -> (String, URL?)? in
                guard let feed = podcast.feed?.absoluteString else { return nil }
                return (feed, podcast.imageURL)
            },
            by: \.0
        )
        .mapValues { $0.first?.1 }
        let coversByTitle = Dictionary(grouping: podcasts, by: \.title)
            .mapValues { $0.first?.imageURL }

        let summaries = try summaries(in: range, period: period, context: context)
        let summaryRollups = rollups(
            from: summaries,
            coversByFeed: coversByFeed,
            coversByTitle: coversByTitle
        )
        if !summaryRollups.isEmpty {
            return summaryRollups
        }

        let stats = try listeningStats(in: range, context: context)
        return rollups(
            from: stats,
            coversByFeed: coversByFeed,
            coversByTitle: coversByTitle
        )
    }

    private func resolvedBackground(
        _ background: PodcastShareShortcutBackground,
        for periodStart: Date,
        period: PlaySessionSummaryPeriod
    ) -> TopPodcastShareBackground {
        guard background == .automatic else {
            return background.shareBackground
        }

        if period == .year {
            return .newYear
        }

        switch calendar.component(.month, from: periodStart) {
        case 1:
            return .january
        case 2:
            return .february
        case 3:
            return .march
        case 4:
            return .april
        case 5:
            return .may
        case 6:
            return .june
        case 7:
            return .july
        case 8:
            return .august
        case 9:
            return .september
        case 10:
            return .october
        case 11:
            return .november
        default:
            return .december
        }
    }

    private func summaries(
        in range: Range<Date>,
        period: PlaySessionSummaryPeriod,
        context: ModelContext
    ) throws -> [PlaySessionSummary] {
        let kind = period.rawValue
        let descriptor = FetchDescriptor<PlaySessionSummary>()
        return try context.fetch(descriptor).filter { summary in
            guard summary.periodKind == kind, let periodStart = summary.periodStart else {
                return false
            }
            return range.contains(periodStart)
        }
    }

    private func listeningStats(in range: Range<Date>, context: ModelContext) throws -> [ListeningStat] {
        let descriptor = FetchDescriptor<ListeningStat>()
        return try context.fetch(descriptor).filter { stat in
            guard let startOfHour = stat.startOfHour else { return false }
            return range.contains(startOfHour)
        }
    }

    private func rollups(
        from summaries: [PlaySessionSummary],
        coversByFeed: [String: URL?],
        coversByTitle: [String: URL?]
    ) -> [PodcastRollup] {
        Dictionary(grouping: summaries.compactMap { summary -> (String, URL?, String, Double)? in
            let totalSeconds = summary.totalSeconds ?? 0
            guard totalSeconds > 0 else { return nil }
            let feed = summary.podcastFeed
            let name = summary.podcastName ?? "Unknown Podcast"
            let key = feed?.absoluteString ?? name
            return (key, feed, name, totalSeconds)
        }, by: \.0)
        .map { _, values in
            let first = values[0]
            let feed = first.1
            let name = first.2
            return PodcastRollup(
                podcastName: name,
                podcastFeed: feed,
                coverURL: feed.flatMap { coversByFeed[$0.absoluteString] ?? nil } ?? coversByTitle[name] ?? nil,
                totalSeconds: values.reduce(0) { $0 + $1.3 }
            )
        }
        .sorted { $0.totalSeconds > $1.totalSeconds }
    }

    private func rollups(
        from stats: [ListeningStat],
        coversByFeed: [String: URL?],
        coversByTitle: [String: URL?]
    ) -> [PodcastRollup] {
        Dictionary(grouping: stats.compactMap { stat -> (String, URL?, String, Double)? in
            let totalSeconds = stat.totalSeconds ?? 0
            guard totalSeconds > 0 else { return nil }
            let feed = stat.podcastFeed
            let name = stat.podcastName ?? "Unknown Podcast"
            let key = feed?.absoluteString ?? name
            return (key, feed, name, totalSeconds)
        }, by: \.0)
        .map { _, values in
            let first = values[0]
            let feed = first.1
            let name = first.2
            return PodcastRollup(
                podcastName: name,
                podcastFeed: feed,
                coverURL: feed.flatMap { coversByFeed[$0.absoluteString] ?? nil } ?? coversByTitle[name] ?? nil,
                totalSeconds: values.reduce(0) { $0 + $1.3 }
            )
        }
        .sorted { $0.totalSeconds > $1.totalSeconds }
    }

    private func stats(
        rollups: [PodcastRollup],
        start: Date,
        end: Date,
        period: PlaySessionSummaryPeriod,
        context: ModelContext
    ) -> TopPodcastShareStats {
        let listeningStats = (try? listeningStats(in: start..<end, context: context)) ?? []
        let topPodcast = rollups.first
        let busiestDay = busiestDayLabel(from: listeningStats)
        let busiestHour = busiestHourLabel(from: listeningStats)
        let sessionCount = activeSessionCount(in: start..<end, context: context)

        return TopPodcastShareStats(
            title: sharePeriodLabel(for: start, period: period),
            dateRangeLabel: dateRangeLabel(start: start, end: end),
            topPodcastName: topPodcast?.podcastName ?? "No data yet",
            topPodcastListeningTime: topPodcast.map { formatDuration($0.totalSeconds) } ?? "0m",
            totalListeningTime: formatDuration(rollups.reduce(0) { $0 + $1.totalSeconds }),
            podcastCount: rollups.count,
            listeningSessionCount: sessionCount,
            busiestDayLabel: busiestDay,
            busiestHourLabel: busiestHour
        )
    }

    private func activeSessionCount(in range: Range<Date>, context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<PlaySession>()
        return ((try? context.fetch(descriptor)) ?? []).filter { session in
            guard let startTime = session.startTime else { return false }
            return range.contains(startTime)
        }.count
    }

    private func busiestDayLabel(from stats: [ListeningStat]) -> String {
        let totals = Dictionary(grouping: stats, by: { stat in
            stat.startOfHour.map { calendar.component(.weekday, from: $0) } ?? 0
        })
        .mapValues { values in
            values.reduce(0) { $0 + ($1.totalSeconds ?? 0) }
        }
        guard let busiest = totals.max(by: { $0.value < $1.value }), busiest.value > 0 else {
            return "No data yet"
        }

        let symbols = DateFormatter().weekdaySymbols ?? []
        let symbolIndex = busiest.key - 1
        guard symbols.indices.contains(symbolIndex) else { return "No data yet" }
        return symbols[symbolIndex]
    }

    private func busiestHourLabel(from stats: [ListeningStat]) -> String {
        let totals = Dictionary(grouping: stats, by: { stat in
            stat.startOfHour.map { calendar.component(.hour, from: $0) } ?? 0
        })
        .mapValues { values in
            values.reduce(0) { $0 + ($1.totalSeconds ?? 0) }
        }
        guard let busiest = totals.max(by: { $0.value < $1.value }), busiest.value > 0 else {
            return "No data yet"
        }

        var components = DateComponents()
        components.hour = busiest.key
        components.minute = 0
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: formatter.locale)

        guard let date = calendar.date(from: components) else {
            return String(format: "%02d:00", busiest.key)
        }
        return formatter.string(from: date)
    }

    private func targetDate(for period: PlaySessionSummaryPeriod, timing: PodcastShareShortcutTiming) -> Date {
        let now = Date()
        guard timing == .previous else { return now }
        switch period {
        case .day:
            return calendar.date(byAdding: .day, value: -1, to: now) ?? now
        case .week:
            return calendar.date(byAdding: .weekOfYear, value: -1, to: now) ?? now
        case .month:
            return calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .year:
            return calendar.date(byAdding: .year, value: -1, to: now) ?? now
        }
    }

    private func periodStart(for date: Date, period: PlaySessionSummaryPeriod) -> Date {
        switch period {
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        case .year:
            return calendar.dateInterval(of: .year, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }

    private func nextPeriodStart(from date: Date, period: PlaySessionSummaryPeriod) -> Date {
        switch period {
        case .day:
            return calendar.date(byAdding: .day, value: 1, to: date) ?? date
        case .week:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date) ?? date
        case .month:
            return calendar.date(byAdding: .month, value: 1, to: date) ?? date
        case .year:
            return calendar.date(byAdding: .year, value: 1, to: date) ?? date
        }
    }

    private func sharePeriodLabel(for date: Date, period: PlaySessionSummaryPeriod) -> String {
        switch period {
        case .day:
            return date.formatted(date: .abbreviated, time: .omitted)
        case .week:
            let components = calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: date)
            let week = components.weekOfYear ?? 0
            let year = components.yearForWeekOfYear ?? calendar.component(.year, from: date)
            return "Week \(week), \(year)"
        case .month:
            return date.formatted(.dateTime.month(.wide).year())
        case .year:
            return date.formatted(.dateTime.year())
        }
    }

    private func dateRangeLabel(start: Date, end: Date) -> String {
        let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: end) ?? end
        let cappedEnd = min(inclusiveEnd, calendar.startOfDay(for: Date()))
        if calendar.isDate(start, inSameDayAs: cappedEnd) {
            return localizedDateString(for: start)
        }

        let formatter = DateIntervalFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: start, to: cappedEnd)
    }

    private func localizedDateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0m" }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

private enum PodcastShareShortcutError: LocalizedError {
    case noListeningHistory
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .noListeningHistory:
            return "No listening history is available for the selected period and design."
        case .renderFailed:
            return "The podcast share image could not be rendered."
        }
    }
}

private extension String {
    var filenameSafe: String {
        components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
