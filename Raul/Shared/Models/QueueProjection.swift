import Foundation

/// A sendable snapshot of the fields needed by queue lists and filters.
///
/// Queue screens must not pass SwiftData models between actors or retain a
/// second, view-owned queue. This value is rebuilt from the ordered result of
/// PlaylistModelActor whenever the authoritative playlist changes.
struct QueueEpisodeValue: Identifiable, Equatable, Hashable, Sendable {
    let stableIdentityKey: String
    let episodeURL: URL
    let title: String
    let podcastTitle: String
    let podcastFeedURL: URL?
    let artworkURL: URL?
    let duration: TimeInterval?
    let playPosition: TimeInterval
    let maxPlayPosition: TimeInterval
    let hasPlaybackHistory: Bool
    let isPlayed: Bool
    let isDownloaded: Bool
    let categories: [String]
    let occurrence: Int
    let orderIndex: Int

    var id: String {
        occurrence == 0 ? stableIdentityKey : "\(stableIdentityKey)#\(occurrence)"
    }

    var remainingDuration: TimeInterval? {
        guard let duration, duration.isFinite, duration >= 0 else { return nil }
        let position = min(max(playPosition.isFinite ? playPosition : 0, 0), duration)
        return max(0, duration - position)
    }

    var progress: Double {
        guard let duration, duration.isFinite, duration > 0 else { return 0 }
        let position = max(max(playPosition, maxPlayPosition), 0)
        return min(max(position / duration, 0), 1)
    }

    init(episode: Episode, occurrence: Int = 0, orderIndex: Int = 0) {
        self.stableIdentityKey = episode.stableEpisodeIdentityKey
        self.episodeURL = episode.url ?? URL(string: "about:blank")!
        self.title = episode.title
        self.podcastTitle = episode.displayPodcastTitle ?? ""
        self.podcastFeedURL = episode.podcast?.feed
        self.artworkURL = episode.imageURL ?? episode.podcast?.imageURL
        self.duration = episode.duration
        self.playPosition = episode.metaData?.playPosition ?? 0
        self.maxPlayPosition = episode.metaData?.maxPlayposition ?? 0
        self.hasPlaybackHistory = episode.hasPlaybackHistory
        self.isPlayed = episode.isPlayed
        let localFile = episode.localFile?.standardizedFileURL
        let fileInventoryContainsEpisode = localFile.map {
            DownloadedFilesManager.shared.downloadedFiles.contains($0)
        } ?? false
        self.isDownloaded = episode.source == .sideLoaded
            || fileInventoryContainsEpisode
            || episode.metaData?.calculatedIsAvailableLocally == true
        self.categories = SmartPlaylistEngine.categories(for: episode.podcast?.optionalTags)
        self.occurrence = occurrence
        self.orderIndex = orderIndex
    }

    init(
        stableIdentityKey: String,
        episodeURL: URL,
        title: String,
        podcastTitle: String,
        podcastFeedURL: URL? = nil,
        artworkURL: URL? = nil,
        duration: TimeInterval? = nil,
        playPosition: TimeInterval = 0,
        maxPlayPosition: TimeInterval = 0,
        hasPlaybackHistory: Bool = false,
        isPlayed: Bool = false,
        isDownloaded: Bool = false,
        categories: [String] = [],
        occurrence: Int = 0,
        orderIndex: Int = 0
    ) {
        self.stableIdentityKey = stableIdentityKey
        self.episodeURL = episodeURL
        self.title = title
        self.podcastTitle = podcastTitle
        self.podcastFeedURL = podcastFeedURL
        self.artworkURL = artworkURL
        self.duration = duration
        self.playPosition = playPosition
        self.maxPlayPosition = maxPlayPosition
        self.hasPlaybackHistory = hasPlaybackHistory
        self.isPlayed = isPlayed
        self.isDownloaded = isDownloaded
        self.categories = categories
        self.occurrence = occurrence
        self.orderIndex = orderIndex
    }
}

struct QueueProjection: Equatable, Sendable {
    let playlistID: UUID?
    let playlistTitle: String
    let isSmartPlaylist: Bool
    let entries: [QueueEpisodeValue]

    init(
        playlistID: UUID? = nil,
        playlistTitle: String = Playlist.defaultQueueDisplayName,
        isSmartPlaylist: Bool = false,
        episodes: [Episode]
    ) {
        self.playlistID = playlistID
        self.playlistTitle = playlistTitle
        self.isSmartPlaylist = isSmartPlaylist

        var occurrenceByIdentity: [String: Int] = [:]
        self.entries = episodes.enumerated().compactMap { index, episode in
            guard episode.url != nil else { return nil }
            let identity = episode.stableEpisodeIdentityKey
            let occurrence = occurrenceByIdentity[identity, default: 0]
            occurrenceByIdentity[identity] = occurrence + 1
            return QueueEpisodeValue(episode: episode, occurrence: occurrence, orderIndex: index)
        }
    }

    init(
        playlistID: UUID? = nil,
        playlistTitle: String = Playlist.defaultQueueDisplayName,
        isSmartPlaylist: Bool = false,
        entries: [QueueEpisodeValue]
    ) {
        self.playlistID = playlistID
        self.playlistTitle = playlistTitle
        self.isSmartPlaylist = isSmartPlaylist
        self.entries = entries
    }

    var count: Int { entries.count }

    var knownRemainingDuration: TimeInterval? {
        let durations = entries.compactMap(\.remainingDuration)
        guard durations.isEmpty == false else { return nil }
        return durations.reduce(0, +)
    }

    var hasUnknownDuration: Bool {
        entries.contains { $0.remainingDuration == nil }
    }

    func filtered(using state: QueueFilterState) -> QueueProjection {
        guard state.isFiltering else { return self }
        return QueueProjection(
            playlistID: playlistID,
            playlistTitle: playlistTitle,
            isSmartPlaylist: isSmartPlaylist,
            entries: entries.filter { state.matches($0) }
        )
    }

    func upcoming(after episodeURL: URL) -> UpcomingQueueSnapshot {
        guard let currentIndex = entries.firstIndex(where: { $0.episodeURL == episodeURL }) else {
            return UpcomingQueueSnapshot(
                playlistID: playlistID,
                playlistTitle: playlistTitle,
                isSmartPlaylist: isSmartPlaylist,
                currentEpisodeURL: episodeURL,
                upcoming: [],
                isIndependentPlayback: true
            )
        }

        return UpcomingQueueSnapshot(
            playlistID: playlistID,
            playlistTitle: playlistTitle,
            isSmartPlaylist: isSmartPlaylist,
            currentEpisodeURL: episodeURL,
            upcoming: Array(entries.dropFirst(currentIndex + 1)),
            isIndependentPlayback: false
        )
    }
}

struct QueueFilterState: Equatable, Sendable {
    static let defaultShortDurationMinutes = 30.0

    var inProgress = false
    var maximumDurationMinutes: Double?
    var downloadedOnly = false
    var podcastTitle: String?
    var category: String?
    var minimumDurationMinutes: Double?

    static let all = QueueFilterState()

    var isFiltering: Bool {
        inProgress
            || maximumDurationMinutes != nil
            || downloadedOnly
            || podcastTitle != nil
            || category != nil
            || minimumDurationMinutes != nil
    }

    var isShortSelected: Bool {
        maximumDurationMinutes == Self.defaultShortDurationMinutes
            && minimumDurationMinutes == nil
    }

    var activeFilterCount: Int {
        [inProgress, maximumDurationMinutes != nil, downloadedOnly,
         podcastTitle != nil, category != nil, minimumDurationMinutes != nil]
            .filter { $0 }
            .count
    }

    mutating func clear() {
        self = .all
    }

    func matches(_ episode: QueueEpisodeValue) -> Bool {
        if inProgress && (!episode.hasPlaybackHistory || episode.isPlayed) {
            return false
        }
        if downloadedOnly && !episode.isDownloaded {
            return false
        }
        if let maximumDurationMinutes {
            guard let duration = episode.duration,
                  duration.isFinite,
                  duration / 60 <= maximumDurationMinutes else { return false }
        }
        if let minimumDurationMinutes {
            guard let duration = episode.duration,
                  duration.isFinite,
                  duration / 60 >= minimumDurationMinutes else { return false }
        }
        if let podcastTitle,
           episode.podcastTitle.caseInsensitiveCompare(podcastTitle) != .orderedSame {
            return false
        }
        if let category,
           episode.categories.contains(where: {
               $0.caseInsensitiveCompare(category) == .orderedSame
           }) == false {
            return false
        }
        return true
    }
}

struct UpcomingQueueSnapshot: Equatable, Sendable {
    let playlistID: UUID?
    let playlistTitle: String
    let isSmartPlaylist: Bool
    let currentEpisodeURL: URL
    let upcoming: [QueueEpisodeValue]
    let isIndependentPlayback: Bool

    var upcomingCount: Int { upcoming.count }

    var remainingDuration: TimeInterval? {
        let durations = upcoming.compactMap(\.remainingDuration)
        guard durations.isEmpty == false else { return nil }
        return durations.reduce(0, +)
    }
}

enum QueueProjectionFormatting {
    static func duration(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return Duration.seconds(seconds).formatted(.units(width: .narrow))
    }

    static func countAndDuration(
        count: Int,
        duration: TimeInterval?,
        hasUnknownDuration: Bool = false
    ) -> String {
        let episodeText = String(localized: "\(count) episodes")
        guard let seconds = duration,
              let durationText = QueueProjectionFormatting.duration(seconds) else {
            return hasUnknownDuration
                ? String(localized: "\(episodeText) · duration unavailable")
                : episodeText
        }
        let suffix = hasUnknownDuration ? "+" : ""
        return String(localized: "\(episodeText) · \(suffix)\(durationText) remaining")
    }
}
