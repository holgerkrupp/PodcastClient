import Foundation
import SwiftData

@Model
final class StoreSplitMigrationCheckpoint: Identifiable {
    var id: String = ""
    var migrationVersion: Int = 0
    var phase: String = ""
    var cursor: String?
    var startedAt: Date?
    var completedAt: Date?
    var scannedCount: Int = 0
    var insertedCount: Int = 0
    var updatedCount: Int = 0
    var skippedCount: Int = 0
    var failedCount: Int = 0
    var failedItemKeys: [String] = []
    var lastError: String?
    var updatedAt: Date = Date.distantPast

    init(
        id: String,
        migrationVersion: Int,
        phase: String,
        cursor: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        scannedCount: Int = 0,
        insertedCount: Int = 0,
        updatedCount: Int = 0,
        skippedCount: Int = 0,
        failedCount: Int = 0,
        failedItemKeys: [String] = [],
        lastError: String? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.migrationVersion = migrationVersion
        self.phase = phase
        self.cursor = cursor
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.scannedCount = scannedCount
        self.insertedCount = insertedCount
        self.updatedCount = updatedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.failedItemKeys = failedItemKeys
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

@Model
final class CachedFeedExtensionElement: Identifiable {
    var id: String = ""
    var feedURL: String = ""
    var episodeID: String?
    var scope: String = ""
    var namespaceURI: String = ""
    var qualifiedName: String = ""
    var localName: String = ""
    var payload: Data = Data()
    var ordinal: Int = 0
    var contentHash: String = ""
    var updatedAt: Date = Date.distantPast

    init(
        feedURL: String,
        episodeID: String? = nil,
        scope: String,
        namespaceURI: String,
        qualifiedName: String,
        localName: String,
        payload: Data,
        ordinal: Int,
        contentHash: String,
        updatedAt: Date = .now
    ) {
        self.id = StableIdentityKey.make(
            feedURL,
            episodeID ?? "__feed__",
            namespaceURI,
            qualifiedName,
            String(ordinal)
        )
        self.feedURL = feedURL
        self.episodeID = episodeID
        self.scope = scope
        self.namespaceURI = namespaceURI
        self.qualifiedName = qualifiedName
        self.localName = localName
        self.payload = payload
        self.ordinal = ordinal
        self.contentHash = contentHash
        self.updatedAt = updatedAt
    }
}

/// Local-only cache of feed-derivable podcast data. Lives in `PodcastCache.sqlite`
/// (`cloudKitDatabase: .none`) so this bulk, rebuildable data never syncs to
/// iCloud. Everything here can be reconstructed by re-parsing the RSS feed; user
/// state (subscription, play position, bookmarks) is NOT stored here — it lives in
/// the CloudKit-backed `UserState.sqlite`.
///
/// Relationships to other *cache* models are allowed; cross-store references use
/// scalar keys (`feedURL`) only — never a SwiftData relationship across stores.
@Model
final class CachedPodcast: Identifiable {
    /// Normalized feed-URL key — the stable feed identity shared across stores.
    var id: String = ""
    var feedURL: String = ""
    var title: String = ""
    var desc: String?
    var author: String?
    var feed: URL?
    var link: URL?
    var language: String?
    var copyright: String?
    var imageURL: URL?
    var lastBuildDate: Date?
    var funding: [FundingInfo] = []
    var social: [SocialInfo] = []
    var people: [PersonInfo] = []
    var alternativeFeeds: [PodcastAlternativeFeed] = []
    var optionalTags: PodcastNamespaceOptionalTags?

    /// Version of the cache projection that has been fully written for this
    /// feed. Existing Phase 2 rows default to 1, which lets the Phase 3
    /// bootstrap revisit them once to add chapters, transcripts and download
    /// records without repeatedly scanning feeds that legitimately have none.
    var cacheSchemaVersion: Int = 1

    // Device-local, rebuildable feed-refresh diagnostics.
    var lastRefresh: Date?
    var feedUpdated: Bool?
    var feedUpdateCheckDate: Date?
    var consecutiveFeedFailureCount: Int = 0
    var lastFeedFailureDate: Date?
    var lastFeedFailureStatusCode: Int?
    var lastFeedFailureMessage: String?

    var updatedAt: Date = Date.distantPast

    @Relationship(deleteRule: .cascade, inverse: \CachedEpisode.podcast)
    var episodes: [CachedEpisode]? = []

    init(
        id: String,
        feedURL: String,
        title: String = "",
        desc: String? = nil,
        author: String? = nil,
        feed: URL? = nil,
        link: URL? = nil,
        language: String? = nil,
        copyright: String? = nil,
        imageURL: URL? = nil,
        lastBuildDate: Date? = nil,
        funding: [FundingInfo] = [],
        social: [SocialInfo] = [],
        people: [PersonInfo] = [],
        alternativeFeeds: [PodcastAlternativeFeed] = [],
        optionalTags: PodcastNamespaceOptionalTags? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.feedURL = feedURL
        self.title = title
        self.desc = desc
        self.author = author
        self.feed = feed
        self.link = link
        self.language = language
        self.copyright = copyright
        self.imageURL = imageURL
        self.lastBuildDate = lastBuildDate
        self.funding = funding
        self.social = social
        self.people = people
        self.alternativeFeeds = alternativeFeeds
        self.optionalTags = optionalTags
        self.updatedAt = updatedAt
    }
}

/// Local-only cache of feed-derivable episode data. See `CachedPodcast`. User play
/// state and bookmarks are kept out of here — they belong to `UserState.sqlite`.
@Model
final class CachedEpisode: Identifiable {
    /// Stable episode identity (GUID/enclosure/link/hash precedence).
    var id: String = ""
    /// Owner feed key — scalar cross-store reference to subscription/user state.
    var feedURL: String = ""
    var guid: String?
    var title: String = ""
    var author: String?
    var desc: String?
    var subtitle: String?
    var content: String?
    var publishDate: Date?
    var url: URL?
    var deeplinks: [URL]?
    var fileSize: Int64?
    var mediaType: String?
    var link: URL?
    var imageURL: URL?
    var duration: Double?
    var number: String?
    var typeRawValue: String?
    var sourceRawValue: String = EpisodeSource.feedDownload.rawValue
    var externalFiles: [ExternalFile] = []
    var funding: [FundingInfo] = []
    var social: [SocialInfo] = []
    var people: [PersonInfo] = []
    var optionalTags: PodcastNamespaceOptionalTags?

    var updatedAt: Date = Date.distantPast

    var podcast: CachedPodcast?

    init(
        id: String,
        feedURL: String,
        guid: String? = nil,
        title: String = "",
        author: String? = nil,
        desc: String? = nil,
        subtitle: String? = nil,
        content: String? = nil,
        publishDate: Date? = nil,
        url: URL? = nil,
        deeplinks: [URL]? = nil,
        fileSize: Int64? = nil,
        mediaType: String? = nil,
        link: URL? = nil,
        imageURL: URL? = nil,
        duration: Double? = nil,
        number: String? = nil,
        typeRawValue: String? = nil,
        sourceRawValue: String = EpisodeSource.feedDownload.rawValue,
        externalFiles: [ExternalFile] = [],
        funding: [FundingInfo] = [],
        social: [SocialInfo] = [],
        people: [PersonInfo] = [],
        optionalTags: PodcastNamespaceOptionalTags? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.feedURL = feedURL
        self.guid = guid
        self.title = title
        self.author = author
        self.desc = desc
        self.subtitle = subtitle
        self.content = content
        self.publishDate = publishDate
        self.url = url
        self.deeplinks = deeplinks
        self.fileSize = fileSize
        self.mediaType = mediaType
        self.link = link
        self.imageURL = imageURL
        self.duration = duration
        self.number = number
        self.typeRawValue = typeRawValue
        self.sourceRawValue = sourceRawValue
        self.externalFiles = externalFiles
        self.funding = funding
        self.social = social
        self.people = people
        self.optionalTags = optionalTags
        self.updatedAt = updatedAt
    }
}

/// Cache-local chapter data. Bookmark markers are intentionally excluded: they
/// are user-owned and live in `BookmarkSync` instead.
@Model
final class CachedChapter: Identifiable {
    var id: String = ""
    var feedURL: String = ""
    var episodeID: String = ""
    var sourceUUID: String?
    var title: String = ""
    var link: URL?
    var imageURL: URL?
    var imageData: Data?
    var start: Double?
    var endTime: Double?
    var duration: Double?
    var creationTime: Date?
    var progress: Double?
    var typeRawValue: String = MarkerType.unknown.rawValue
    var shouldPlay: Bool = true
    var ordinal: Int = 0
    var updatedAt: Date = Date.distantPast

    init(
        id: String,
        feedURL: String,
        episodeID: String,
        sourceUUID: String? = nil,
        title: String = "",
        link: URL? = nil,
        imageURL: URL? = nil,
        imageData: Data? = nil,
        start: Double? = nil,
        endTime: Double? = nil,
        duration: Double? = nil,
        creationTime: Date? = nil,
        progress: Double? = nil,
        typeRawValue: String = MarkerType.unknown.rawValue,
        shouldPlay: Bool = true,
        ordinal: Int = 0,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.feedURL = feedURL
        self.episodeID = episodeID
        self.sourceUUID = sourceUUID
        self.title = title
        self.link = link
        self.imageURL = imageURL
        self.imageData = imageData
        self.start = start
        self.endTime = endTime
        self.duration = duration
        self.creationTime = creationTime
        self.progress = progress
        self.typeRawValue = typeRawValue
        self.shouldPlay = shouldPlay
        self.ordinal = ordinal
        self.updatedAt = updatedAt
    }
}

/// Publisher or locally generated transcript text kept out of CloudKit. Synced
/// AI transcript revisions are materialized into this cache only after their
/// manifest and chunks have been validated.
@Model
final class CachedTranscriptLine: Identifiable {
    var id: String = ""
    var feedURL: String = ""
    var episodeID: String = ""
    var sourceUUID: String?
    var speaker: String?
    var text: String = ""
    var startTime: Double = 0
    var endTime: Double?
    var ordinal: Int = 0
    var updatedAt: Date = Date.distantPast

    init(
        id: String,
        feedURL: String,
        episodeID: String,
        sourceUUID: String? = nil,
        speaker: String? = nil,
        text: String = "",
        startTime: Double = 0,
        endTime: Double? = nil,
        ordinal: Int = 0,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.feedURL = feedURL
        self.episodeID = episodeID
        self.sourceUUID = sourceUUID
        self.speaker = speaker
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.ordinal = ordinal
        self.updatedAt = updatedAt
    }
}

/// Device-local transcription job history. This is diagnostics/history rather
/// than transcript content and never belongs in the synchronized store.
@Model
final class CachedTranscriptionRecord: Identifiable {
    var id: String = ""
    var feedURL: String = ""
    var episodeID: String = ""
    var episodeURL: URL?
    var episodeTitle: String = ""
    var podcastTitle: String?
    var localeIdentifier: String = ""
    var startedAt: Date = Date.distantPast
    var finishedAt: Date = Date.distantPast
    var audioDuration: Double = 0
    var transcriptionDuration: Double = 0
    var updatedAt: Date = Date.distantPast

    init(
        id: String,
        feedURL: String,
        episodeID: String,
        episodeURL: URL? = nil,
        episodeTitle: String = "",
        podcastTitle: String? = nil,
        localeIdentifier: String = "",
        startedAt: Date = .distantPast,
        finishedAt: Date = .distantPast,
        audioDuration: Double = 0,
        transcriptionDuration: Double = 0,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.feedURL = feedURL
        self.episodeID = episodeID
        self.episodeURL = episodeURL
        self.episodeTitle = episodeTitle
        self.podcastTitle = podcastTitle
        self.localeIdentifier = localeIdentifier
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.audioDuration = audioDuration
        self.transcriptionDuration = transcriptionDuration
        self.updatedAt = updatedAt
    }
}

/// Cache-local index of the expected audio file and its current availability.
/// The audio itself remains in the caches directory.
@Model
final class CachedDownloadRecord: Identifiable {
    var id: String = ""
    var feedURL: String = ""
    var episodeID: String = ""
    var remoteURL: URL?
    var localFileURL: URL?
    var isAvailableLocally: Bool = false
    var fileSize: Int64?
    var updatedAt: Date = Date.distantPast

    init(
        id: String,
        feedURL: String,
        episodeID: String,
        remoteURL: URL? = nil,
        localFileURL: URL? = nil,
        isAvailableLocally: Bool = false,
        fileSize: Int64? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.feedURL = feedURL
        self.episodeID = episodeID
        self.remoteURL = remoteURL
        self.localFileURL = localFileURL
        self.isAvailableLocally = isAvailableLocally
        self.fileSize = fileSize
        self.updatedAt = updatedAt
    }
}

enum FeedAliasReason: String, Codable, Sendable {
    case permanentRedirect
    case explicitSwitch
}

/// Local mapping between an obsolete feed key and the accepted replacement.
/// User-state records keep their original stable key during the transition;
/// repositories resolve aliases when composing cache and sync snapshots.
@Model
final class FeedAlias: Identifiable {
    var id: String = ""
    var oldFeedURL: String = ""
    var newFeedURL: String = ""
    var reasonRawValue: String = FeedAliasReason.permanentRedirect.rawValue
    var updatedAt: Date = Date.distantPast

    init(
        oldFeedURL: String,
        newFeedURL: String,
        reason: FeedAliasReason,
        updatedAt: Date = .now
    ) {
        self.id = StableIdentityKey.make(oldFeedURL)
        self.oldFeedURL = oldFeedURL
        self.newFeedURL = newFeedURL
        self.reasonRawValue = reason.rawValue
        self.updatedAt = updatedAt
    }
}

@Model
final class AppliedAIContentRevision: Identifiable {
    var id: String = ""
    var transcriptRevisionID: String?
    var chapterRevisionID: String?
    var updatedAt: Date = Date.distantPast

    init(
        episodeIdentityKey: String,
        transcriptRevisionID: String? = nil,
        chapterRevisionID: String? = nil,
        updatedAt: Date = .now
    ) {
        self.id = episodeIdentityKey
        self.transcriptRevisionID = transcriptRevisionID
        self.chapterRevisionID = chapterRevisionID
        self.updatedAt = updatedAt
    }
}
