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
#if canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers

/*
struct PlayerIntentsExtension: AppIntent {
    static var title: LocalizedStringResource { "PlayerIntentsExtension" }
    
    func perform() async throws -> some IntentResult {
        return .result()
    }
}
*/

#if canImport(UIKit)
struct FastExportClipIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Podcast Clip"
    static let description = IntentDescription("Directly exports an audio clip from the currently playing episode without opening the app.")

    // Run entirely in the background
    static let openAppWhenRun: Bool = false

    // Parameter 1: Configurable offset backward (Defaults to 15 seconds ago)
    @Parameter(
        title: "Backwards Offset",
        description: "How many seconds prior to the current position the clip should start.",
        default: 15.0
    )
    var offset: Double

    // Parameter 2: Configurable total clip duration (Defaults to 30 seconds long)
    @Parameter(
        title: "Clip Length",
        description: "The total duration of the generated clip in seconds.",
        default: 30.0
    )
    var clipLength: Double

    @MainActor
    func perform() async throws -> some ReturnsValue<IntentFile> & ProvidesDialog {
        // 1. Gather live playback data from your Player coordinator
        guard let currentEpisode = Player.shared.currentEpisode,
              let audioURL = Player.shared.currentEpisode?.localFile else {
            throw NSError(domain: "ExportClipIntent", code: 404, userInfo: [NSLocalizedDescriptionKey: "No active episode found to clip."])
        }
        
        let playPosition = Player.shared.playPosition
        let totalDuration = Player.shared.currentEpisode?.duration ?? 0

        // 2. Math Calculations for Trim Range
        // Start time is current position minus the backward offset
        let trimStart = max(0, playPosition - offset)
        // End time is start time plus the requested clip length (bounded by absolute duration)
        let trimEnd = min(totalDuration, trimStart + clipLength)
        
        // Ensure we have a valid slicing range
        guard trimEnd > trimStart else {
            throw NSError(domain: "ExportClipIntent", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid clip durations calculated."])
        }

        // 3. Background Audio Export
        // Since we don't have a UI view, we fetch the cover image directly in the background task
        let coverImage: UIImage
        if let url = currentEpisode.imageURL, let loaded = await ImageLoaderAndCache.loadUIImage(from: url) {
            coverImage = loaded
        }  else {
            coverImage = UIImage() // Fallback empty layout canvas
        }
        do {
            // Trigger your asynchronous export logic immediately
            let generatedURL = try await AudioClipExporter.exportClipAsync(
                audioURL: audioURL,
                title: currentEpisode.title,
                coverImage: coverImage,
                startTime: trimStart,
                endTime: trimEnd,
                playbackRate: Player.shared.playbackRate,
                fps: 30,
                videoSize: CGSize(width: 720, height: 720)
            ) { _ in
                // Progress callback unneeded for instant background executions,
                // but required by your method signature
            }

            // 4. Wrap the generated media asset into an IntentFile
            let clipName = "\(currentEpisode.title ?? "Clip")-\(Int(trimStart))s"
            let intentFile = IntentFile(fileURL: generatedURL, filename: "\(clipName).mp4")
            
            // 5. Speak back confirmation and hand the physical file directly over to Siri/Shortcuts
            let dialog = IntentDialog("Here is your \(Int(clipLength)) second clip from '\(currentEpisode.title)'.")
            
            return .result(value: intentFile, dialog: dialog)

        } catch {
         
            throw NSError(domain: "ExportClipIntent", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed rendering clip background process: \(error.localizedDescription)"])
        }
    }
}
#endif



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

enum PlayPodcastEpisodeError: Error, CustomLocalizedStringResourceConvertible {
    case libraryUnavailable
    case podcastNotFound
    case episodeNotFound
    case episodeHasNoAudio

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .libraryUnavailable:
            "The podcast library is unavailable."
        case .podcastNotFound:
            "That podcast could not be found in your library."
        case .episodeNotFound:
            "That episode could not be found."
        case .episodeHasNoAudio:
            "That episode has no playable audio."
        }
    }
}

struct SiriEpisodeRequestEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Podcast Episode")
    static let defaultQuery = SiriEpisodeRequestQuery()

    let podcastTitle: String
    let episodeNumber: Int

    var id: String {
        "\(episodeNumber)|\(podcastTitle)"
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(podcastTitle) episode \(episodeNumber)")
    }

    init(podcastTitle: String, episodeNumber: Int) {
        self.podcastTitle = podcastTitle
        self.episodeNumber = episodeNumber
    }

    init?(spokenRequest: String) {
        let cleanedRequest = spokenRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"(?i)^(.+?)\s+(?:episode|ep\.?|folge|#)\s*(\d+)\s*$"#,
            #"(?i)^(?:episode|ep\.?|folge|#)\s*(\d+)\s+(?:of|from|von)\s+(.+?)\s*$"#
        ]

        for (index, pattern) in patterns.enumerated() {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: cleanedRequest,
                    range: NSRange(cleanedRequest.startIndex..., in: cleanedRequest)
                  ),
                  match.numberOfRanges == 3,
                  let firstRange = Range(match.range(at: 1), in: cleanedRequest),
                  let secondRange = Range(match.range(at: 2), in: cleanedRequest) else {
                continue
            }

            let firstValue = String(cleanedRequest[firstRange])
            let secondValue = String(cleanedRequest[secondRange])
            let podcastTitle = index == 0 ? firstValue : secondValue
            let numberValue = index == 0 ? secondValue : firstValue

            if let episodeNumber = Int(numberValue) {
                self.init(
                    podcastTitle: podcastTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                    episodeNumber: episodeNumber
                )
                return
            }
        }

        return nil
    }
}

struct SiriEpisodeRequestQuery: EntityStringQuery {
    func entities(for identifiers: [SiriEpisodeRequestEntity.ID]) async throws -> [SiriEpisodeRequestEntity] {
        identifiers.compactMap { identifier in
            guard let separator = identifier.firstIndex(of: "|"),
                  let episodeNumber = Int(identifier[..<separator]) else {
                return nil
            }

            let titleStart = identifier.index(after: separator)
            return SiriEpisodeRequestEntity(
                podcastTitle: String(identifier[titleStart...]),
                episodeNumber: episodeNumber
            )
        }
    }

    func entities(matching string: String) async throws -> [SiriEpisodeRequestEntity] {
        guard let request = SiriEpisodeRequestEntity(spokenRequest: string) else {
            return []
        }
        return [request]
    }

    func suggestedEntities() async throws -> [SiriEpisodeRequestEntity] {
        []
    }
}

struct PlayPodcastEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Podcast Episode"
    static let description = IntentDescription("Play a numbered episode from a podcast in your library.")
    static let openAppWhenRun = false

    @Parameter(
        title: "Podcast and Episode",
        description: "For example, Bits und so episode 900, or episode 900 of Bits und so.",
        requestValueDialog: "Which podcast and episode?"
    )
    var request: SiriEpisodeRequestEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$request)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try await preparedIntentModelContainer()

        let podcastDescriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate { $0.metaData?.isSubscribed != false }
        )
        let podcasts = try container.mainContext.fetch(podcastDescriptor)
        guard let storedPodcast = bestPodcastMatch(
            for: request.podcastTitle,
            in: podcasts
        ) else {
            throw PlayPodcastEpisodeError.podcastNotFound
        }

        let requestedNumber = String(request.episodeNumber)
        let episodes = storedPodcast.episodes ?? []
        let matchingEpisode = episodes.first {
            $0.number?.trimmingCharacters(in: .whitespacesAndNewlines) == requestedNumber
        } ?? episodes.first {
            titleContainsEpisodeNumber($0.title, episodeNumber: request.episodeNumber)
        }

        guard let matchingEpisode else {
            throw PlayPodcastEpisodeError.episodeNotFound
        }
        guard let episodeURL = matchingEpisode.url else {
            throw PlayPodcastEpisodeError.episodeHasNoAudio
        }

        await Player.shared.playEpisode(episodeURL, playDirectly: true)
        return .result(dialog: "Playing episode \(request.episodeNumber) of \(storedPodcast.title).")
    }

    private func bestPodcastMatch(for requestedTitle: String, in podcasts: [Podcast]) -> Podcast? {
        let normalizedRequest = normalized(requestedTitle)
        let rankedMatches = podcasts.compactMap { podcast -> (podcast: Podcast, rank: Int)? in
            let normalizedTitle = normalized(podcast.title)
            if normalizedTitle == normalizedRequest {
                return (podcast, 0)
            }
            if normalizedTitle.contains(normalizedRequest) || normalizedRequest.contains(normalizedTitle) {
                return (podcast, 1)
            }
            return nil
        }

        return rankedMatches.min {
            if $0.rank != $1.rank {
                return $0.rank < $1.rank
            }
            return $0.podcast.title.count < $1.podcast.title.count
        }?.podcast
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func titleContainsEpisodeNumber(_ title: String, episodeNumber: Int) -> Bool {
        let escapedNumber = NSRegularExpression.escapedPattern(for: String(episodeNumber))
        let pattern = #"(?i)(?:episode|ep\.?|folge|#)\s*"# + escapedNumber + #"(?!\d)"#
        return title.range(of: pattern, options: .regularExpression) != nil
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
        /*
        AppShortcut(
                    intent: FastExportClipIntent(),
                    phrases: [
                        "Export a clip from \(.applicationName)",
                        "Grab a clip starting \(\.$offset) seconds ago on \(.applicationName)",
                        "Make a \(\.$clipLength) second clip on \(.applicationName)"
                    ],
                    shortTitle: "Direct Clip Export",
                    systemImageName: "scissors"
                )
        */
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
            intent: PlayPodcastEpisodeIntent(),
            phrases: [
                "Play \(\.$request) in \(.applicationName)",
                "Play \(\.$request) with \(.applicationName)"
            ],
            shortTitle: "Play Podcast Episode",
            systemImageName: "play.circle"
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

    }
}

struct RefreshPodcastFeedsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh podcasts"
    static let description = IntentDescription("Check subscribed podcast feeds for new episodes.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try await preparedIntentModelContainer()
        await SubscriptionManager(modelContainer: container).bgupdateFeeds()
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
    case forever

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Podcast Share Period")
    static let caseDisplayRepresentations: [PodcastShareShortcutPeriod: DisplayRepresentation] = [
        .day: "Day",
        .week: "Week",
        .month: "Month",
        .year: "Year",
        .forever: "Forever"
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
        case .forever:
            return .forever
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
    case calendar
    case yearCalendar

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Podcast Share Design")
    static let caseDisplayRepresentations: [PodcastShareShortcutDesign: DisplayRepresentation] = [
        .podium: "Podium Top 3",
        .billboard: "Billboard Top 10",
        .coverGrid: "Cover Grid",
        .coverCollage: "Cover Collage",
        .coverCloud: "Cover Cloud",
        .horizontalBars: "Playtime Bars",
        .pieChart: "Playtime Pie",
        .statistics: "Stats Wrapped",
        .calendar: "Calendar",
        .yearCalendar: "Year Calendar"
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
        case .calendar:
            return .calendar
        case .yearCalendar:
            return .yearCalendar
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
        let container = try await preparedIntentModelContainer()
        let context = ModelContext(container)
        let targetDate = targetDate(for: request.period, timing: request.timing)
        let start = periodStart(for: targetDate, period: request.period)
        let end = nextPeriodStart(from: start, period: request.period)
        guard request.design.supports(period: request.period) else {
            throw PodcastShareShortcutError.noListeningHistory
        }
        let rollups = try podcastRollups(in: start..<end, period: request.period, context: context)
        guard rollups.count >= request.design.minimumItemCount else {
            throw PodcastShareShortcutError.noListeningHistory
        }

        let designRollups = request.design.usesAllItems ? rollups : Array(rollups.prefix(request.design.itemLimit))
        let items = await topPodcastShareItems(from: designRollups)
        let timelineEntries = await topPodcastShareTimelineEntries(
            from: try timelineRollups(in: start..<end, context: context)
        )
        let totalListeningSeconds = rollups.reduce(0) { $0 + $1.totalSeconds }
        let renderSize = TopPodcastShareAspect.renderSize(for: request.aspectRatio.videoSize)
        let background = resolvedBackground(request.background, for: start, period: request.period)
        let shareDateRangeLabel = request.period == .forever
            ? historyDateRangeLabel(in: start..<end, context: context)
            : dateRangeLabel(start: start, end: end)
        let image = renderTopPodcastShareImage(
            items: items,
            design: request.design,
            periodLabel: sharePeriodLabel(for: start, period: request.period),
            dateRangeLabel: shareDateRangeLabel,
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
            period: request.period,
            periodStart: start,
            timelineEntries: timelineEntries,
            usesMonthlyMiniMonthBackgrounds: false,
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

        let summaries = try bestSummaries(in: range, period: period, context: context)
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
        if period == .forever {
            return .current
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

    private func bestSummaries(
        in range: Range<Date>,
        period: PlaySessionSummaryPeriod,
        context: ModelContext
    ) throws -> [PlaySessionSummary] {
        if period != .forever {
            return try summaries(in: range, period: period, context: context)
        }

        for fallbackPeriod in [PlaySessionSummaryPeriod.year, .month, .week, .day] {
            let values = try summaries(in: range, period: fallbackPeriod, context: context)
            if !values.isEmpty {
                return values
            }
        }
        return []
    }

    private func listeningStats(in range: Range<Date>, context: ModelContext) throws -> [ListeningStat] {
        let descriptor = FetchDescriptor<ListeningStat>()
        return try context.fetch(descriptor).filter { stat in
            guard let startOfHour = stat.startOfHour else { return false }
            return range.contains(startOfHour)
        }
    }

    private func timelineRollups(
        in range: Range<Date>,
        context: ModelContext
    ) throws -> [TopPodcastShareTimelineRollup] {
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

        let statRollups: [TopPodcastShareTimelineRollup] = try listeningStats(in: range, context: context).compactMap { stat -> TopPodcastShareTimelineRollup? in
            guard let date = stat.startOfHour, let totalSeconds = stat.totalSeconds, totalSeconds > 0 else { return nil }
            let feed = stat.podcastFeed
            let name = stat.podcastName ?? "Unknown Podcast"
            return TopPodcastShareTimelineRollup(
                date: date,
                podcastName: name,
                podcastFeed: feed,
                coverURL: feed.flatMap { coversByFeed[$0.absoluteString] ?? nil } ?? coversByTitle[name] ?? nil,
                totalSeconds: totalSeconds
            )
        }

        let daysWithHourlyStats = Set(statRollups.map { calendar.startOfDay(for: $0.date) })
        let daySummaryRollups: [TopPodcastShareTimelineRollup] = try summaries(in: range, period: .day, context: context).compactMap { summary -> TopPodcastShareTimelineRollup? in
            guard
                let date = summary.periodStart,
                !daysWithHourlyStats.contains(calendar.startOfDay(for: date)),
                let totalSeconds = summary.totalSeconds,
                totalSeconds > 0
            else {
                return nil
            }

            let feed = summary.podcastFeed
            let name = summary.podcastName ?? "Unknown Podcast"
            return TopPodcastShareTimelineRollup(
                date: date,
                podcastName: name,
                podcastFeed: feed,
                coverURL: feed.flatMap { coversByFeed[$0.absoluteString] ?? nil } ?? coversByTitle[name] ?? nil,
                totalSeconds: totalSeconds
            )
        }

        let weekRollups = try fallbackSummaryRollups(
            summaries: summaries(in: range, period: .week, context: context),
            period: .week,
            existingRollups: statRollups + daySummaryRollups,
            coversByFeed: coversByFeed,
            coversByTitle: coversByTitle
        )
        let monthRollups = try fallbackSummaryRollups(
            summaries: summaries(in: range, period: .month, context: context),
            period: .month,
            existingRollups: statRollups + daySummaryRollups + weekRollups,
            coversByFeed: coversByFeed,
            coversByTitle: coversByTitle
        )

        return (statRollups + daySummaryRollups + weekRollups + monthRollups)
        .sorted { $0.date < $1.date }
    }

    private func fallbackSummaryRollups(
        summaries: [PlaySessionSummary],
        period: PlaySessionSummaryPeriod,
        existingRollups: [TopPodcastShareTimelineRollup],
        coversByFeed: [String: URL?],
        coversByTitle: [String: URL?]
    ) throws -> [TopPodcastShareTimelineRollup] {
        summaries.compactMap { summary -> TopPodcastShareTimelineRollup? in
            guard
                let date = summary.periodStart,
                let totalSeconds = summary.totalSeconds,
                totalSeconds > 0,
                !existingRollups.contains(where: { rollup in
                    rollup.podcastFeed == summary.podcastFeed
                    && isDate(rollup.date, inPeriodStarting: date, period: period)
                })
            else {
                return nil
            }

            let feed = summary.podcastFeed
            let name = summary.podcastName ?? "Unknown Podcast"
            return TopPodcastShareTimelineRollup(
                date: date,
                podcastName: name,
                podcastFeed: feed,
                coverURL: feed.flatMap { coversByFeed[$0.absoluteString] ?? nil } ?? coversByTitle[name] ?? nil,
                totalSeconds: totalSeconds,
                coveragePeriod: period
            )
        }
    }

    private func isDate(_ date: Date, inPeriodStarting periodStart: Date, period: PlaySessionSummaryPeriod) -> Bool {
        let end: Date
        switch period {
        case .day:
            end = calendar.date(byAdding: .day, value: 1, to: periodStart) ?? periodStart
        case .week:
            end = calendar.date(byAdding: .weekOfYear, value: 1, to: periodStart) ?? periodStart
        case .month:
            end = calendar.date(byAdding: .month, value: 1, to: periodStart) ?? periodStart
        case .year:
            end = calendar.date(byAdding: .year, value: 1, to: periodStart) ?? periodStart
        case .forever:
            end = .distantFuture
        }
        return date >= periodStart && date < end
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
            dateRangeLabel: period == .forever ? historyDateRangeLabel(in: start..<end, context: context) : dateRangeLabel(start: start, end: end),
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

        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        let symbols = formatter.weekdaySymbols ?? []
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
        case .forever:
            return now
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
        case .forever:
            return .distantPast
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
        case .forever:
            return .distantFuture
        }
    }

    private func sharePeriodLabel(for date: Date, period: PlaySessionSummaryPeriod) -> String {
        switch period {
        case .day:
            return localizedDateString(for: date)
        case .week:
            let end = calendar.date(byAdding: .day, value: 6, to: date) ?? date
            return dateRangeLabel(start: date, end: end)
        case .month:
            return localizedMonthYearString(for: date)
        case .year:
            return localizedYearString(for: date)
        case .forever:
            return "Forever"
        }
    }

    private func dateRangeLabel(start: Date, end: Date) -> String {
        if start == .distantPast {
            return "All time"
        }
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

    private func historyDateRangeLabel(in range: Range<Date>, context: ModelContext) -> String {
        var preciseStarts: [Date] = []
        var preciseEnds: [Date] = []
        var summaryStarts: [Date] = []
        var summaryEnds: [Date] = []

        let summaries = (try? context.fetch(FetchDescriptor<PlaySessionSummary>())) ?? []
        for summary in summaries {
            guard let start = summary.periodStart, range.contains(start) else { continue }
            summaryStarts.append(start)
            if
                let rawPeriod = summary.periodKind,
                let period = PlaySessionSummaryPeriod(rawValue: rawPeriod)
            {
                summaryEnds.append(calendarEnd(for: start, period: period))
            } else {
                summaryEnds.append(start)
            }
        }

        let stats = (try? listeningStats(in: range, context: context)) ?? []
        preciseStarts.append(contentsOf: stats.compactMap(\.startOfHour))
        preciseEnds.append(contentsOf: stats.compactMap(\.startOfHour))

        let sessions = ((try? context.fetch(FetchDescriptor<PlaySession>())) ?? []).filter { session in
            guard let start = session.startTime else { return false }
            return range.contains(start)
        }
        preciseStarts.append(contentsOf: sessions.compactMap(\.startTime))
        preciseEnds.append(contentsOf: sessions.compactMap { $0.endTime ?? $0.startTime })

        guard let start = preciseStarts.min() ?? summaryStarts.min() else {
            return "All time"
        }
        let end = preciseEnds.max() ?? summaryEnds.max() ?? start
        return dateRangeLabel(start: start, end: min(end, calendar.startOfDay(for: Date())))
    }

    private func calendarEnd(for start: Date, period: PlaySessionSummaryPeriod) -> Date {
        let exclusiveEnd = nextPeriodStart(from: start, period: period)
        return calendar.date(byAdding: .day, value: -1, to: exclusiveEnd) ?? start
    }

    private func localizedDateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func localizedMonthYearString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("MMMM y")
        return formatter.string(from: date)
    }

    private func localizedYearString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("y")
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

@MainActor
private func preparedIntentModelContainer() async throws -> ModelContainer {
    let manager = ModelContainerManager.shared
    if let container = manager.preparedContainer {
        return container
    }
#if canImport(UIKit)
    guard UIApplication.shared.applicationState == .active else {
        throw IntentModelContainerError.unavailable(
            "Open Up Next before running this action so the podcast library can finish loading."
        )
    }
#endif
    await manager.prepareContainer()
    guard let container = manager.preparedContainer else {
        throw IntentModelContainerError.unavailable(
            manager.initializationError ?? "The podcast library could not be opened."
        )
    }
    return container
}

private enum IntentModelContainerError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        }
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
