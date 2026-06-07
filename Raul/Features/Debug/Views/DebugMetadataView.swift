#if DEBUG
import Foundation
import SwiftData
import SwiftUI
import UIKit

struct AppDebugMetadataView: View {
    @Environment(DownloadedFilesManager.self) private var downloadedFilesManager
    @AppStorage("goingToBackgroundDate") private var goingToBackgroundDate: Date?
    @AppStorage(OnboardingPreferenceKeys.didCompleteOnboarding) private var didCompleteOnboarding: Bool = false
    @AppStorage(PlaylistPreferenceKeys.selectedPlaylistID) private var selectedPlaylistID: String = ""
    @AppStorage(PlaylistPreferenceKeys.inboxBasePlaylistID) private var inboxBasePlaylistID: String = ""
    @AppStorage(SideloadingConfiguration.enabledKey) private var sideloadingEnabled = false

    @Query(sort: \Podcast.title) private var podcasts: [Podcast]
    @Query private var episodes: [Episode]
    @Query(sort: [SortDescriptor(\Playlist.sortIndex, order: .forward), SortDescriptor(\Playlist.title, order: .forward)]) private var playlists: [Playlist]
    @Query private var podcastSettings: [PodcastSettings]
    @Query private var transcriptionRecords: [TranscriptionRecord]
    @Query private var transcriptLines: [TranscriptLineAndTime]
    @Query private var playSessions: [PlaySession]
    @Query private var listeningStats: [ListeningStat]
    @Query private var playSessionSummaries: [PlaySessionSummary]

    var body: some View {
        List {
            DebugSection("App") {
                DebugRow("Bundle ID", value: Bundle.main.bundleIdentifier)
                DebugRow("Version", value: appVersion)
                DebugRow("Build", value: appBuild)
                DebugRow("Device", value: UIDevice.current.model)
                DebugRow("System", value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                DebugRow("Locale", value: Locale.current.identifier)
                DebugRow("Time Zone", value: TimeZone.current.identifier)
                DebugRow("Now", date: Date())
            }

            DebugSection("Refresh") {
                DebugRow("Latest Podcast Refresh", date: latestPodcastRefresh)
                DebugRow("Oldest Podcast Refresh", date: oldestPodcastRefresh)
                DebugRow("Latest Feed Check", date: latestFeedCheck)
                DebugRow("Oldest Feed Check", date: oldestFeedCheck)
                DebugRow("Latest Feed Build Date", date: latestFeedBuildDate)
                DebugRow("Never Refreshed Podcasts", value: "\(podcasts.filter { $0.metaData?.lastRefresh == nil }.count)")
                DebugRow("Never Checked Podcasts", value: "\(podcasts.filter { $0.metaData?.feedUpdateCheckDate == nil }.count)")
                DebugRow("Feeds Marked Updated", value: "\(podcasts.filter { $0.metaData?.feedUpdated == true }.count)")
                DebugRow("Metadata Updating", value: "\(podcasts.filter { $0.metaData?.isUpdating == true }.count)")
                DebugRow("Feeds With Failure Streak", value: "\(podcasts.filter { ($0.metaData?.consecutiveFeedFailureCount ?? 0) > 0 }.count)")
                DebugRow("Likely Abandoned Feeds", value: "\(likelyAbandonedPodcasts.count)")
            }

            DebugSection("Library Counts") {
                DebugRow("Podcasts", value: "\(podcasts.count)")
                DebugRow("Subscribed Podcasts", value: "\(subscribedPodcasts.count)")
                DebugRow("Unsubscribed Podcasts", value: "\(podcasts.count - subscribedPodcasts.count)")
                DebugRow("Episodes", value: "\(episodes.count)")
                DebugRow("Inbox Episodes", value: "\(episodes.filter { $0.metaData?.status == .inbox || $0.metaData?.isInbox == true }.count)")
                DebugRow("History Episodes", value: "\(episodes.filter { $0.metaData?.status == .history || $0.metaData?.isHistory == true }.count)")
                DebugRow("Archived Episodes", value: "\(episodes.filter { $0.metaData?.status == .archived || $0.metaData?.isArchived == true }.count)")
                DebugRow("Side Loaded Episodes", value: "\(episodes.filter { $0.source == .sideLoaded }.count)")
                DebugRow("Downloaded Files Snapshot", value: "\(downloadedFilesManager.downloadedFiles.count)")
                DebugRow("Episodes Available Locally", value: "\(episodes.filter { $0.metaData?.calculatedIsAvailableLocally == true }.count)")
            }

            DebugSection("Playback") {
                DebugRow("Current Episode", value: Player.shared.currentEpisode?.title)
                DebugRow("Current Podcast", value: Player.shared.currentEpisode?.displayPodcastTitle)
                DebugRow("Current Episode URL", url: Player.shared.currentEpisodeURL)
                DebugRow("Play Position", duration: Player.shared.playPosition)
                DebugRow("Remaining", duration: Player.shared.remaining)
                DebugRow("Playback Speed", value: "\(Player.shared.playbackRate)x")
                DebugRow("Is Playing", value: Player.shared.isPlaying.description)
                DebugRow("Player Sheet Presented", value: Player.shared.isPlayerSheetPresented.description)
            }

            DebugSection("Playlists & Settings") {
                DebugRow("Playlists", value: "\(playlists.count)")
                DebugRow("Visible Manual Playlists", value: "\(Playlist.manualVisibleSorted(playlists).count)")
                DebugRow("Playlist Entries", value: "\(playlists.reduce(0) { $0 + ($1.items?.count ?? 0) })")
                DebugRow("Podcast Settings Records", value: "\(podcastSettings.count)")
                DebugRow("Global Settings Records", value: "\(podcastSettings.filter { $0.title == PodcastSettingsView.defaultSettingsTitle }.count)")
                DebugRow("Podcast Custom Settings", value: "\(podcasts.filter { $0.settings?.isEnabled == true }.count)")
                DebugRow("Selected Playlist ID", value: selectedPlaylistID)
                DebugRow("Inbox Base Playlist ID", value: inboxBasePlaylistID)
            }

            DebugSection("Transcripts & Analytics") {
                DebugRow("Transcript Lines", value: "\(transcriptLines.count)")
                DebugRow("Episodes With Transcript Lines", value: "\(episodes.filter { $0.transcriptLines?.isEmpty == false }.count)")
                DebugRow("Episodes With Remote Transcript Files", value: "\(episodes.filter { $0.externalFiles.contains(where: { $0.category == .transcript }) }.count)")
                DebugRow("Transcription Records", value: "\(transcriptionRecords.count)")
                DebugRow("Latest Transcription", date: transcriptionRecords.map(\.finishedAt).max())
                DebugRow("Play Sessions", value: "\(playSessions.count)")
                DebugRow("Latest Play Session", date: playSessions.compactMap(\.startTime).max())
                DebugRow("Listening Stats", value: "\(listeningStats.count)")
                DebugRow("Latest Listening Stat", date: listeningStats.compactMap(\.startOfHour).max())
                DebugRow("Play Session Summaries", value: "\(playSessionSummaries.count)")
            }

            DebugSection("User Defaults") {
                DebugRow("Completed Onboarding", value: didCompleteOnboarding.description)
                DebugRow("Sideloading Enabled", value: sideloadingEnabled.description)
                DebugRow("Went To Background", date: goingToBackgroundDate)
                DebugRow("Last Storage Cleanup", date: UserDefaults.standard.object(forKey: BackgroundTaskConfiguration.lastStorageCleanupKey) as? Date)
                DebugRow("Last Foreground Download Cleanup", date: UserDefaults.standard.object(forKey: BackgroundTaskConfiguration.lastForegroundDownloadCleanupKey) as? Date)
                DebugRow("Sideloading Missing State", value: UserDefaults.standard.data(forKey: SideloadingConfiguration.missingStateDefaultsKey).map { "\($0.count) bytes" })
            }

            DebugSection("Filesystem") {
                DebugRow("Documents", url: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
                DebugRow("Caches", url: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
                DebugRow("Temporary", url: FileManager.default.temporaryDirectory)
            }

            DebugCollectionSection(title: "Recently Refreshed Podcasts", items: recentlyRefreshedPodcasts) { podcast in
                [
                    ("Title", podcast.title),
                    ("Feed", podcast.feed?.absoluteString),
                    ("Last Refresh", podcast.metaData?.lastRefresh.map(DebugFormat.date)),
                    ("Feed Check", podcast.metaData?.feedUpdateCheckDate.map(DebugFormat.date)),
                    ("Subscribed", podcast.isSubscribed.description),
                    ("Episodes", "\(podcast.episodes?.count ?? 0)")
                ]
            }

            DebugCollectionSection(title: "Likely Abandoned Podcasts", items: likelyAbandonedPodcasts) { podcast in
                [
                    ("Title", podcast.title),
                    ("Feed", podcast.feed?.absoluteString),
                    ("HTTP Status", podcast.metaData?.lastFeedFailureStatusCode.map(String.init)),
                    ("Failures", podcast.metaData.map { "\($0.consecutiveFeedFailureCount)" }),
                    ("First Failure", podcast.metaData?.firstConsecutiveFeedFailureDate.map(DebugFormat.date)),
                    ("Last Failure", podcast.metaData?.lastFeedFailureDate.map(DebugFormat.date)),
                    ("Error", podcast.metaData?.lastFeedFailureMessage)
                ]
            }
        }
        .navigationTitle("App Debug")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private var appBuild: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    private var subscribedPodcasts: [Podcast] {
        podcasts.filter(\.isSubscribed)
    }

    private var latestPodcastRefresh: Date? {
        podcasts.compactMap { $0.metaData?.lastRefresh }.max()
    }

    private var oldestPodcastRefresh: Date? {
        podcasts.compactMap { $0.metaData?.lastRefresh }.min()
    }

    private var latestFeedCheck: Date? {
        podcasts.compactMap { $0.metaData?.feedUpdateCheckDate }.max()
    }

    private var oldestFeedCheck: Date? {
        podcasts.compactMap { $0.metaData?.feedUpdateCheckDate }.min()
    }

    private var latestFeedBuildDate: Date? {
        podcasts.compactMap(\.lastBuildDate).max()
    }

    private var recentlyRefreshedPodcasts: [Podcast] {
        podcasts
            .sorted { ($0.metaData?.lastRefresh ?? .distantPast) > ($1.metaData?.lastRefresh ?? .distantPast) }
            .prefix(10)
            .map { $0 }
    }

    private var likelyAbandonedPodcasts: [Podcast] {
        return podcasts
            .filter { $0.metaData?.isFeedLikelyAbandoned == true }
            .sorted {
                ($0.metaData?.firstConsecutiveFeedFailureDate ?? .distantFuture)
                    < ($1.metaData?.firstConsecutiveFeedFailureDate ?? .distantFuture)
            }
    }
}

struct EpisodeDebugMetadataView: View {
    let episode: Episode

    var body: some View {
        List {
            DebugSection("Identity") {
                DebugRow("Persistent ID", value: String(describing: episode.persistentModelID))
                DebugRow("GUID", value: episode.guid)
                DebugRow("Source", value: episode.source.rawValue)
                DebugRow("Podcast", value: episode.displayPodcastTitle)
                DebugRow("Podcast ID", value: episode.podcast.map { String(describing: $0.persistentModelID) })
            }

            DebugSection("Episode") {
                DebugRow("Title", value: episode.title)
                DebugRow("Author", value: episode.author)
                DebugRow("Subtitle", value: episode.subtitle, limit: 180)
                DebugRow("Description", value: episode.desc, limit: 180)
                DebugRow("Content", value: episode.content, limit: 180)
                DebugRow("Type", value: episode.type?.rawValue)
                DebugRow("Number", value: episode.number)
                DebugRow("Publish Date", date: episode.publishDate)
                DebugRow("Duration", duration: episode.duration)
                DebugRow("Remaining Time", duration: episode.remainingTime)
                DebugRow("File Size", bytes: episode.fileSize)
            }

            DebugSection("URLs") {
                DebugRow("Audio URL", url: episode.url)
                DebugRow("Local File", url: episode.localFile)
                DebugRow("Local File Exists", value: episode.localFile.map { FileManager.default.fileExists(atPath: $0.path).description })
                DebugRow("Link", url: episode.link)
                DebugRow("Image URL", url: episode.imageURL)
                DebugRows("Deep Links", values: episode.deeplinks?.map(\.absoluteString) ?? [])
            }

            if let metaData = episode.metaData {
                DebugSection("Playback Metadata") {
                    DebugRow("Status", value: metaData.status?.rawValue)
                    DebugRow("System Suppression", value: metaData.systemSuppressionReasonRawValue)
                    DebugRow("Available Locally Stored", value: metaData.isAvailableLocally.description)
                    DebugRow("Available Locally Calculated", value: metaData.calculatedIsAvailableLocally.description)
                    DebugRow("Archived", value: metaData.isArchived?.description)
                    DebugRow("History", value: metaData.isHistory?.description)
                    DebugRow("Inbox", value: metaData.isInbox?.description)
                    DebugRow("Was Skipped", value: metaData.wasSkipped.description)
                    DebugRow("Play Position", duration: metaData.playPosition)
                    DebugRow("Max Play Position", duration: metaData.maxPlayposition)
                    DebugRow("Play Progress", value: episode.playProgress.formatted(.percent.precision(.fractionLength(1))))
                    DebugRow("Max Play Progress", value: episode.maxPlayProgress.formatted(.percent.precision(.fractionLength(1))))
                    DebugRow("Last Played", date: metaData.lastPlayed)
                    DebugRow("First Listen", date: metaData.firstListenDate)
                    DebugRow("Completion Date", date: metaData.completionDate)
                    DebugRow("Archived At", date: metaData.archivedAt)
                    DebugRow("Total Listen Time", duration: metaData.totalListenTime)
                    DebugRows("Playback Starts", values: metaData.playbackStartTimes?.elements.map { DebugFormat.date($0) } ?? [])
                    DebugRows("Playback Durations", values: metaData.playbackDurations?.elements.map { DebugFormat.duration($0) } ?? [])
                    DebugRows("Playback Speeds", values: metaData.playbackSpeeds?.elements.map { "\($0)x" } ?? [])
                }
            } else {
                DebugSection("Playback Metadata") {
                    DebugRow("Metadata", value: nil)
                }
            }

            DebugSection("Relationships") {
                DebugRow("Chapters", value: "\(episode.chapters?.count ?? 0)")
                DebugRow("Preferred Chapters", value: "\(episode.preferredChapters.count)")
                DebugRow("Bookmarks", value: "\(episode.bookmarks?.count ?? 0)")
                DebugRow("Transcript Lines", value: "\(episode.transcriptLines?.count ?? 0)")
                DebugRow("Play Sessions", value: "\(episode.playSessions?.count ?? 0)")
                DebugRow("Playlist Entries", value: "\(episode.playlist?.count ?? 0)")
            }

            DebugCollectionSection(title: "External Files", items: episode.externalFiles) { file in
                [
                    ("URL", file.url),
                    ("Category", file.category?.rawValue),
                    ("Source", file.source),
                    ("File Type", file.fileType)
                ]
            }

            DebugSharedMetadataSections(
                funding: episode.funding,
                social: episode.social,
                people: episode.people,
                optionalTags: episode.optionalTags
            )
        }
        .navigationTitle("Episode Debug")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PodcastDebugMetadataView: View {
    let podcast: Podcast

    var body: some View {
        List {
            DebugSection("Identity") {
                DebugRow("Persistent ID", value: String(describing: podcast.persistentModelID))
                DebugRow("Title", value: podcast.title)
                DebugRow("Author", value: podcast.author)
                DebugRow("Language", value: podcast.language)
                DebugRow("Copyright", value: podcast.copyright)
            }

            DebugSection("Feed") {
                DebugRow("Feed URL", url: podcast.feed)
                DebugRow("Website", url: podcast.link)
                DebugRow("Image URL", url: podcast.imageURL)
                DebugRow("Directory URL", url: podcast.directoryURL)
                DebugRow("Description", value: podcast.desc, limit: 180)
                DebugRow("Last Build Date", date: podcast.lastBuildDate)
                DebugRow("Message", value: podcast.message)
            }

            if let metaData = podcast.metaData {
                DebugSection("Subscription Metadata") {
                    DebugRow("Subscribed", value: podcast.isSubscribed.description)
                    DebugRow("Last Refresh", date: metaData.lastRefresh)
                    DebugRow("Feed Updated", value: metaData.feedUpdated?.description)
                    DebugRow("Feed Update Check Date", date: metaData.feedUpdateCheckDate)
                    DebugRow("Consecutive Failures", value: "\(metaData.consecutiveFeedFailureCount)")
                    DebugRow("First Failure", date: metaData.firstConsecutiveFeedFailureDate)
                    DebugRow("Last Failure", date: metaData.lastFeedFailureDate)
                    DebugRow("Last HTTP Status", value: metaData.lastFeedFailureStatusCode.map(String.init))
                    DebugRow("Last Feed Error", value: metaData.lastFeedFailureMessage, limit: 240)
                    DebugRow("Subscription Date", date: metaData.subscriptionDate)
                    DebugRow("Is Updating", value: metaData.isUpdating.description)
                    DebugRow("Message", value: metaData.message)
                }
            } else {
                DebugSection("Subscription Metadata") {
                    DebugRow("Metadata", value: nil)
                }
            }

            if let settings = podcast.settings {
                DebugSection("Settings") {
                    DebugRow("Settings ID", value: settings.id.uuidString)
                    DebugRow("Title", value: settings.title)
                    DebugRow("Enabled", value: settings.isEnabled.description)
                    DebugRow("Auto Download", value: settings.autoDownload.description)
                    DebugRow("Auto Download Count", value: "\(settings.autoDownloadEpisodeCount)")
                    DebugRow("Auto Download Selection", value: settings.autoDownloadSelectionRawValue)
                    DebugRow("Network Mode", value: settings.autoDownloadNetworkModeRawValue)
                    DebugRow("Includes Archived", value: settings.autoDownloadIncludesArchivedEpisodes.description)
                    DebugRow("Play Next Position", value: String(describing: settings.playnextPosition))
                    DebugRow("Default Playlist ID", value: settings.defaultPlaylistID?.uuidString)
                    DebugRow("Playback Speed", value: settings.playbackSpeed.map { "\($0)x" })
                    DebugRow("Cut Front", duration: settings.cutFront.map(Double.init))
                    DebugRow("Cut End", duration: settings.cutEnd.map(Double.init))
                    DebugRow("Skip Forward", value: String(describing: settings.skipForward))
                    DebugRow("Skip Back", value: String(describing: settings.skipBack))
                    DebugRow("Archive Retention Days", value: "\(settings.archiveFileRetentionDays)")
                    DebugRow("Mark Played After Subscribe", value: settings.markAsPlayedAfterSubscribe.description)
                    DebugRow("Adjusted By Play Speed", value: settings.playSumAdjustedbyPlayspeed.description)
                    DebugRow("Lock Screen Slider", value: settings.enableLockscreenSlider.description)
                    DebugRow("In App Slider", value: settings.enableInAppSlider.description)
                    DebugRow("Continuous Play", value: settings.getContinuousPlay.description)
                    DebugRow("Transcriptions", value: settings.enableTranscriptions.description)
                    DebugRow("Automatic Transcriptions", value: settings.enableAutomaticOnDeviceTranscriptions.description)
                    DebugRow("Transcriptions Charging Only", value: settings.limitAutomaticOnDeviceTranscriptionsToCharging.description)
                    DebugRow("Snippet Duration", duration: settings.transcriptionMaxSnippetDurationSeconds)
                    DebugRow("Sleep Add Minutes", value: "\(settings.sleepTimerAddMinutes)")
                    DebugRow("Sleep Reactivate", duration: settings.sleepTimerDurationToReactivate)
                    DebugRow("Sleep Voice Feedback", value: settings.sleepTimerVoiceFeedbackEnabled.description)
                    DebugRow("Sleep Text", value: settings.sleepTimerText)
                    DebugRow("Sleep Voice", value: settings.sleepTimerVoice)
                    DebugRow("Auto Skip Keywords", value: "\(settings.autoSkipKeywords.count)")
                    DebugRow("Voices", value: settings.voices.map { "\($0.count) locales" })
                }
            } else {
                DebugSection("Settings") {
                    DebugRow("Settings", value: nil)
                }
            }

            DebugSection("Relationships") {
                DebugRow("Episodes", value: "\(podcast.episodes?.count ?? 0)")
                DebugRow("Funding Entries", value: "\(podcast.funding.count)")
                DebugRow("Social Entries", value: "\(podcast.social.count)")
                DebugRow("People Entries", value: "\(podcast.people.count)")
            }

            DebugSharedMetadataSections(
                funding: podcast.funding,
                social: podcast.social,
                people: podcast.people,
                optionalTags: podcast.optionalTags
            )
        }
        .navigationTitle("Podcast Debug")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DebugSharedMetadataSections: View {
    let funding: [FundingInfo]
    let social: [SocialInfo]
    let people: [PersonInfo]
    let optionalTags: PodcastNamespaceOptionalTags?

    var body: some View {
        DebugCollectionSection(title: "Funding", items: funding) { item in
            [
                ("Label", item.label),
                ("URL", item.url.absoluteString)
            ]
        }

        DebugCollectionSection(title: "Social", items: social) { item in
            [
                ("Protocol", item.socialprotocol),
                ("URI", item.url.absoluteString),
                ("Account ID", item.accountId),
                ("Account URL", item.accountURL?.absoluteString),
                ("Priority", item.priority.map(String.init))
            ]
        }

        DebugCollectionSection(title: "People", items: people) { item in
            [
                ("Name", item.name),
                ("Role", item.role),
                ("Href", item.href?.absoluteString),
                ("Image", item.img?.absoluteString)
            ]
        }

        DebugSection("Podcast Namespace Tags") {
            if let optionalTags, optionalTags.isEmpty == false {
                ForEach(DebugNamespaceTag.rows(from: optionalTags)) { row in
                    DebugRow(row.name, value: row.value, limit: 260)
                }
            } else {
                DebugRow("Optional Tags", value: nil)
            }
        }
    }
}

struct DebugCollectionSection<Item, Content: View>: View {
    let title: String
    let items: [Item]
    let rows: (Item) -> [(String, String?)]

    init(title: String, items: [Item], rows: @escaping (Item) -> [(String, String?)]) where Content == AnyView {
        self.title = title
        self.items = items
        self.rows = rows
    }

    var body: some View {
        DebugSection("\(title) (\(items.count))") {
            if items.isEmpty {
                DebugRow(title, value: nil)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("#\(index + 1)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(rows(item), id: \.0) { label, value in
                            DebugRow(label, value: value, limit: 220)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

struct DebugSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section(title) {
            content
        }
    }
}

struct DebugRow: View {
    let label: String
    let value: String?
    let limit: Int

    init(_ label: String, value: String?, limit: Int = 120) {
        self.label = label
        self.value = DebugFormat.value(value, limit: limit)
        self.limit = limit
    }

    init(_ label: String, date: Date?) {
        self.init(label, value: date.map(DebugFormat.date))
    }

    init(_ label: String, url: URL?) {
        self.init(label, value: url?.absoluteString, limit: 240)
    }

    init(_ label: String, duration: TimeInterval?) {
        self.init(label, value: duration.map(DebugFormat.duration))
    }

    init(_ label: String, bytes: Int64?) {
        self.init(label, value: bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
    }

    var body: some View {
        LabeledContent(label) {
            Text(value ?? "nil")
                .font(.caption)
                .foregroundStyle(value == nil ? .tertiary : .secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct DebugRows: View {
    let label: String
    let values: [String]

    init(_ label: String, values: [String]) {
        self.label = label
        self.values = values
    }

    var body: some View {
        if values.isEmpty {
            DebugRow(label, value: nil)
        } else {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                DebugRow("\(label) #\(index + 1)", value: value, limit: 240)
            }
        }
    }
}

private enum DebugFormat {
    static func value(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }
        if trimmed.count <= limit {
            return trimmed
        }
        return "\(trimmed.prefix(limit))..."
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .numeric, time: .standard)
    }

    static func duration(_ duration: TimeInterval) -> String {
        "\(Duration.seconds(duration).formatted(.units(width: .abbreviated))) (\(duration.formatted(.number.precision(.fractionLength(2))))s)"
    }
}

private struct DebugNamespaceTag: Identifiable {
    let id = UUID()
    let name: String
    let value: String

    static func rows(from tags: PodcastNamespaceOptionalTags) -> [DebugNamespaceTag] {
        Mirror(reflecting: tags).children.compactMap { child in
            guard let label = child.label,
                  String(describing: child.value) != "nil" else {
                return nil
            }

            let value = String(describing: child.value)
                .replacingOccurrences(of: "Optional(", with: "")
                .replacingOccurrences(of: "))", with: ")")
            return DebugNamespaceTag(name: label, value: value)
        }
    }
}
#endif
