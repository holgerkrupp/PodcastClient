import Foundation

struct WatchSyncChapter: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let start: Double
    let duration: Double?
    let imageURL: String?

    var resolvedImageURL: URL? {
        guard let imageURL else { return nil }
        return URL(string: imageURL)
    }
}

struct WatchSyncEpisode: Codable, Hashable, Identifiable, Sendable {
    let episodeURL: String
    let audioURL: String
    let title: String
    let subtitle: String?
    let podcastTitle: String?
    let publishDate: Date?
    let duration: Double?
    let imageURL: String?
    let phoneHasLocalFile: Bool
    let fileSize: Int64?
    let playPosition: Double?
    let chapters: [WatchSyncChapter]

    var id: String { episodeURL }

    init(
        episodeURL: String,
        audioURL: String,
        title: String,
        subtitle: String?,
        podcastTitle: String?,
        publishDate: Date?,
        duration: Double?,
        imageURL: String?,
        phoneHasLocalFile: Bool,
        fileSize: Int64?,
        playPosition: Double? = nil,
        chapters: [WatchSyncChapter] = []
    ) {
        self.episodeURL = episodeURL
        self.audioURL = audioURL
        self.title = title
        self.subtitle = subtitle
        self.podcastTitle = podcastTitle
        self.publishDate = publishDate
        self.duration = duration
        self.imageURL = imageURL
        self.phoneHasLocalFile = phoneHasLocalFile
        self.fileSize = fileSize
        self.playPosition = playPosition
        self.chapters = chapters
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case episodeURL
        case audioURL
        case title
        case subtitle
        case podcastTitle
        case publishDate
        case duration
        case imageURL
        case phoneHasLocalFile
        case fileSize
        case playPosition
        case chapters
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyID = try container.decodeIfPresent(String.self, forKey: .id)
        episodeURL = try container.decodeIfPresent(String.self, forKey: .episodeURL) ?? legacyID ?? ""
        audioURL = try container.decode(String.self, forKey: .audioURL)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        podcastTitle = try container.decodeIfPresent(String.self, forKey: .podcastTitle)
        publishDate = try container.decodeIfPresent(Date.self, forKey: .publishDate)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        imageURL = try container.decodeIfPresent(String.self, forKey: .imageURL)
        phoneHasLocalFile = try container.decode(Bool.self, forKey: .phoneHasLocalFile)
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
        playPosition = try container.decodeIfPresent(Double.self, forKey: .playPosition)
        chapters = try container.decodeIfPresent([WatchSyncChapter].self, forKey: .chapters) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(episodeURL, forKey: .id)
        try container.encode(episodeURL, forKey: .episodeURL)
        try container.encode(audioURL, forKey: .audioURL)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(podcastTitle, forKey: .podcastTitle)
        try container.encodeIfPresent(publishDate, forKey: .publishDate)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(imageURL, forKey: .imageURL)
        try container.encode(phoneHasLocalFile, forKey: .phoneHasLocalFile)
        try container.encodeIfPresent(fileSize, forKey: .fileSize)
        try container.encodeIfPresent(playPosition, forKey: .playPosition)
        try container.encode(chapters, forKey: .chapters)
    }

    var resolvedEpisodeURL: URL? {
        URL(string: episodeURL)
    }

    var resolvedAudioURL: URL? {
        URL(string: audioURL)
    }

    var resolvedImageURL: URL? {
        guard let imageURL else { return nil }
        return URL(string: imageURL)
    }

    var playbackProgress: Double? {
        guard let playPosition, let duration, duration > 0 else { return nil }
        return min(max(playPosition / duration, 0), 1)
    }

    func chapter(at position: Double?) -> WatchSyncChapter? {
        guard let position else { return nil }
        return chapters.last(where: { $0.start <= position })
    }

    func artworkURL(at position: Double?) -> URL? {
        chapter(at: position)?.resolvedImageURL ?? resolvedImageURL
    }
}

struct WatchSyncPlaylist: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let symbolName: String
    let isSelected: Bool
    let isDefault: Bool

    static let defaultQueue = WatchSyncPlaylist(
        id: "",
        title: "Up Next",
        symbolName: "calendar.day.timeline.leading",
        isSelected: true,
        isDefault: true
    )
}

struct WatchSyncSnapshot: Codable, Sendable {
    let generatedAt: Date
    let playlist: [WatchSyncEpisode]
    let inbox: [WatchSyncEpisode]
    let playlists: [WatchSyncPlaylist]
    let selectedPlaylistID: String?
    let selectedPlaylistTitle: String
    let skipBackSeconds: Int
    let skipForwardSeconds: Int

    static let empty = WatchSyncSnapshot(
        generatedAt: .distantPast,
        playlist: [],
        inbox: [],
        playlists: [WatchSyncPlaylist.defaultQueue],
        selectedPlaylistID: nil,
        selectedPlaylistTitle: WatchSyncPlaylist.defaultQueue.title,
        skipBackSeconds: 15,
        skipForwardSeconds: 30
    )

    init(
        generatedAt: Date,
        playlist: [WatchSyncEpisode],
        inbox: [WatchSyncEpisode],
        playlists: [WatchSyncPlaylist] = [WatchSyncPlaylist.defaultQueue],
        selectedPlaylistID: String? = nil,
        selectedPlaylistTitle: String = WatchSyncPlaylist.defaultQueue.title,
        skipBackSeconds: Int = 15,
        skipForwardSeconds: Int = 30
    ) {
        self.generatedAt = generatedAt
        self.playlist = playlist
        self.inbox = inbox
        self.playlists = playlists
        self.selectedPlaylistID = selectedPlaylistID
        self.selectedPlaylistTitle = selectedPlaylistTitle
        self.skipBackSeconds = skipBackSeconds
        self.skipForwardSeconds = skipForwardSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt
        case playlist
        case inbox
        case playlists
        case selectedPlaylistID
        case selectedPlaylistTitle
        case skipBackSeconds
        case skipForwardSeconds
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        playlist = try container.decode([WatchSyncEpisode].self, forKey: .playlist)
        inbox = try container.decode([WatchSyncEpisode].self, forKey: .inbox)
        playlists = try container.decodeIfPresent([WatchSyncPlaylist].self, forKey: .playlists) ?? [WatchSyncPlaylist.defaultQueue]
        selectedPlaylistID = try container.decodeIfPresent(String.self, forKey: .selectedPlaylistID)
        selectedPlaylistTitle = try container.decodeIfPresent(String.self, forKey: .selectedPlaylistTitle) ?? WatchSyncPlaylist.defaultQueue.title
        skipBackSeconds = try container.decodeIfPresent(Int.self, forKey: .skipBackSeconds) ?? 15
        skipForwardSeconds = try container.decodeIfPresent(Int.self, forKey: .skipForwardSeconds) ?? 30
    }
}

struct WatchStorageSettings: Codable, Hashable, Sendable {
    static let defaultLimitBytes: Int64 = 1_024 * 1_024 * 1_024

    var maxStorageBytes: Int64 = defaultLimitBytes
    var allowCellularDownloads: Bool = false
}

struct WatchStorageReport: Codable, Sendable {
    let generatedAt: Date
    let usedBytes: Int64
    let maxStorageBytes: Int64
    let allowCellularDownloads: Bool
    let downloadedEpisodeIDs: [String]
}

enum WatchCommandKind: String, Codable, Sendable {
    case requestSnapshot
    case refreshInbox
    case queueEpisodeAtFront
    case selectPlaylist
    case syncPlaybackProgress
}

enum WatchCommandPosition: String, Codable, Sendable {
    case front
    case end
}

struct WatchCommand: Codable, Sendable {
    let id: UUID
    let kind: WatchCommandKind
    let episodeID: String?
    let episodeURL: String?
    let playPosition: Double?
    let playlistID: String?
    let position: WatchCommandPosition?

    init(
        kind: WatchCommandKind,
        episodeID: String? = nil,
        episodeURL: String? = nil,
        playPosition: Double? = nil,
        playlistID: String? = nil,
        position: WatchCommandPosition? = nil
    ) {
        self.id = UUID()
        self.kind = kind
        self.episodeID = episodeID
        self.episodeURL = episodeURL
        self.playPosition = playPosition
        self.playlistID = playlistID
        self.position = position
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case episodeID
        case episodeURL
        case playPosition
        case playlistID
        case position
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(WatchCommandKind.self, forKey: .kind)
        episodeID = try container.decodeIfPresent(String.self, forKey: .episodeID)
        episodeURL = try container.decodeIfPresent(String.self, forKey: .episodeURL)
        playPosition = try container.decodeIfPresent(Double.self, forKey: .playPosition)
        playlistID = try container.decodeIfPresent(String.self, forKey: .playlistID)
        position = try container.decodeIfPresent(WatchCommandPosition.self, forKey: .position)
    }
}

enum WatchSyncTransport {
    static let snapshotContextKey = "watchSyncSnapshot"
    static let storageContextKey = "watchSyncStorageReport"
    static let commandMessageKey = "watchSyncCommand"
    static let transferEpisodeIDKey = "watchSyncTransferEpisodeID"
    static let transferEpisodeURLKey = "watchSyncTransferEpisodeURL"

    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}
