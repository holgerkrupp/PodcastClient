import Foundation

struct WatchSyncEpisode: Codable, Hashable, Identifiable, Sendable {
    let id: String
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
}

struct WatchSyncSnapshot: Codable, Sendable {
    let generatedAt: Date
    let playlist: [WatchSyncEpisode]
    let inbox: [WatchSyncEpisode]

    static let empty = WatchSyncSnapshot(generatedAt: .distantPast, playlist: [], inbox: [])
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
}

struct WatchCommand: Codable, Sendable {
    let id: UUID
    let kind: WatchCommandKind
    let episodeID: String?
    let episodeURL: String?

    init(
        kind: WatchCommandKind,
        episodeID: String? = nil,
        episodeURL: String? = nil
    ) {
        self.id = UUID()
        self.kind = kind
        self.episodeID = episodeID
        self.episodeURL = episodeURL
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
