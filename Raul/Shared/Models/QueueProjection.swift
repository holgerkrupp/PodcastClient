import Foundation
import SwiftData

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
    var occurrence: Int
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

    /// `downloadedFiles` and `categories` are supplied by `QueueProjection`
    /// so a whole queue reads the file inventory once and decodes each
    /// podcast's namespace tags once, not once per entry (#498).
    init(
        episode: Episode,
        occurrence: Int = 0,
        orderIndex: Int = 0,
        downloadedFiles: Set<URL>? = nil,
        categories: [String]? = nil
    ) {
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
            (downloadedFiles ?? DownloadedFilesManager.shared.downloadedFiles).contains($0)
        } ?? false
        self.isDownloaded = episode.source == .sideLoaded
            || fileInventoryContainsEpisode
            || episode.metaData?.calculatedIsAvailableLocally == true
        self.categories = categories ?? SmartPlaylistEngine.categories(for: episode.podcast?.optionalTags)
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
        episodes: [Episode],
        downloadedFiles: Set<URL>? = nil
    ) {
        self.playlistID = playlistID
        self.playlistTitle = playlistTitle
        self.isSmartPlaylist = isSmartPlaylist

        let inventory = downloadedFiles ?? DownloadedFilesManager.shared.downloadedFiles
        var occurrenceByIdentity: [String: Int] = [:]
        var categoriesByPodcast: [ObjectIdentifier: [String]] = [:]
        self.entries = episodes.enumerated().compactMap { index, episode in
            guard episode.url != nil else { return nil }
            let identity = episode.stableEpisodeIdentityKey
            let occurrence = occurrenceByIdentity[identity, default: 0]
            occurrenceByIdentity[identity] = occurrence + 1
            let categories: [String]
            if let podcast = episode.podcast {
                let key = ObjectIdentifier(podcast)
                if let cached = categoriesByPodcast[key] {
                    categories = cached
                } else {
                    categories = SmartPlaylistEngine.categories(for: podcast.optionalTags)
                    categoriesByPodcast[key] = categories
                }
            } else {
                categories = []
            }
            return QueueEpisodeValue(
                episode: episode,
                occurrence: occurrence,
                orderIndex: index,
                downloadedFiles: inventory,
                categories: categories
            )
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
        // Presentation IDs must stay unique when the same episode is queued
        // twice, so number repeated identities in order.
        var occurrenceByIdentity: [String: Int] = [:]
        self.entries = entries.map { entry in
            var entry = entry
            let occurrence = occurrenceByIdentity[entry.stableIdentityKey, default: 0]
            occurrenceByIdentity[entry.stableIdentityKey] = occurrence + 1
            entry.occurrence = occurrence
            return entry
        }
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

/// When a cached `QueueProjection` must be rebuilt (#498, #519).
///
/// Membership/order (entry IDs), each entry's episode relationship (an
/// importer can repoint an existing entry without changing its ID), the file
/// inventory, the playing episode, play state, filters and a `generation`
/// bumped by hydration/feed-commit notifications. Reading the related
/// episode's persistent ID uses the entry's own row, so the key never faults
/// episodes and never changes on playback-position ticks.
struct QueueProjectionRebuildKey: Equatable {
    let playlistID: UUID
    let entryIDs: [PersistentIdentifier]
    let episodeIDs: [PersistentIdentifier?]
    let downloadedFiles: Set<URL>
    let currentEpisodeURL: URL?
    let isPlaying: Bool
    let filterState: QueueFilterState
    let generation: Int

    init(
        playlistID: UUID,
        entries: [PlaylistEntry],
        downloadedFiles: Set<URL>,
        currentEpisodeURL: URL?,
        isPlaying: Bool,
        filterState: QueueFilterState,
        generation: Int
    ) {
        self.playlistID = playlistID
        self.entryIDs = entries.map(\.persistentModelID)
        self.episodeIDs = entries.map { $0.episode?.persistentModelID }
        self.downloadedFiles = downloadedFiles
        self.currentEpisodeURL = currentEpisodeURL
        self.isPlaying = isPlaying
        self.filterState = filterState
        self.generation = generation
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
