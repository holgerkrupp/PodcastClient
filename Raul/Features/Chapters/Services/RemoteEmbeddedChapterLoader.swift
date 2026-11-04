import CryptoKit
import Foundation
import mp3ChapterReader
import os

/// Why a remote embedded-chapter read did or didn't produce chapters. Values
/// carry only categories and counts, never URLs, titles or credentials.
enum RemoteChapterOutcome: Equatable, Sendable {
    case success(format: Format, chapterCount: Int, bytes: Int)
    case noEmbeddedChapters(format: Format)
    case unsupportedFormat
    case tagTooLarge(bytes: Int)
    case invalidTag
    case credentialMissing
    case authenticationRejected(status: Int)
    case unauthorizedResource
    case httpStatus(Int)
    case rangeNotSupported
    case timedOut
    case network
    case cancelled
    case skippedInBackground

    enum Format: String, Sendable {
        case mp3 = "MP3 (ID3)"
        case mpeg4 = "MPEG-4"
    }

    /// Worth trying again later; the other outcomes repeat until something changes.
    var isTransient: Bool {
        switch self {
        case .timedOut, .network, .cancelled, .skippedInBackground, .httpStatus:
            return true
        default:
            return false
        }
    }

    var summary: String {
        switch self {
        case .success(let format, let count, let bytes):
            return "\(format.rawValue): \(count) chapter\(count == 1 ? "" : "s") from \(bytes) bytes"
        case .noEmbeddedChapters(let format):
            return "\(format.rawValue): no embedded chapters"
        case .unsupportedFormat:
            return "Not MP3 or MPEG-4 audio"
        case .tagTooLarge(let bytes):
            return "ID3 tag too large (\(bytes) bytes)"
        case .invalidTag:
            return "ID3 tag could not be read"
        case .credentialMissing:
            return "Credentials missing on this device"
        case .authenticationRejected(let status):
            return "Credentials rejected (HTTP \(status))"
        case .unauthorizedResource:
            return "Media host not covered by the podcast credential"
        case .httpStatus(let status):
            return "HTTP \(status)"
        case .rangeNotSupported:
            return "Server did not return the requested byte range"
        case .timedOut:
            return "Timed out"
        case .network:
            return "Network error"
        case .cancelled:
            return "Cancelled"
        case .skippedInBackground:
            return "Skipped while in the background"
        }
    }

    static func classify(_ error: Error) -> RemoteChapterOutcome {
        if let error = error as? RemoteID3TagFetcherError {
            switch error {
            case .invalidHeader: return .unsupportedFormat
            case .unsupportedFormat: return .invalidTag
            case .tagTooLarge(let bytes): return .tagTooLarge(bytes: bytes)
            case .incompleteData: return .rangeNotSupported
            case .networkError(let underlying): return classify(underlying)
            }
        }
        if error is CancellationError { return .cancelled }
        if let error = error as? PodcastRangeRequestError, error == .rangeNotSatisfied { return .rangeNotSupported }
        if let error = error as? PodcastAccessError {
            switch error {
            case .credentialMissing, .credentialKindMismatch, .invalidCredentialURL: return .credentialMissing
            case .unauthorizedResource: return .unauthorizedResource
            case .authenticationFailed: return .authenticationRejected(status: 401)
            }
        }
        if let status = (error as? PodcastHTTPError)?.statusCode {
            return status == 401 || status == 403 ? .authenticationRejected(status: status) : .httpStatus(status)
        }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut
            case .userAuthenticationRequired: return .authenticationRejected(status: 401)
            default: return .network
            }
        }
        return .network
    }
}

/// What the start of a remote media file turned out to be.
enum RemoteMediaProbe: Sendable {
    case id3Tag(Data)
    case mpeg4
    /// Audio without an ID3 tag, so it has no ID3 chapters.
    case untaggedAudio
}

/// Reads embedded chapter metadata from a remote episode with byte-range
/// requests through `PodcastHTTPClient`, so private feeds use their own
/// credentials and redirect rules and no request reads the whole file.
enum RemoteEmbeddedChapterLoader {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UpNext", category: "RemoteChapters")
    static let maximumTagSize = 16 * 1024 * 1024
    private static let tagCache = RemoteID3TagCache()

    /// Fetches the ID3 tag, or identifies MPEG-4 from the same first bytes.
    static func probe(
        _ url: URL,
        profile: PodcastAccessProfile?,
        client: PodcastHTTPClient = .shared
    ) async throws -> RemoteMediaProbe {
        if let cached = await tagCache.cachedTag(for: url, profile: profile) {
            return .id3Tag(cached)
        }
        let header = OSAllocatedUnfairLock<Data?>(initialState: nil)
        do {
            let tag = try await tagCache.tag(for: url, profile: profile) {
                try await fetchID3Tag(maxSize: maximumTagSize) { range in
                    let (data, _) = try await client.rangeData(for: url, range: range, profile: profile)
                    if range.lowerBound == 0, range.count == 10 {
                        header.withLock { $0 = data }
                    }
                    return data
                }
            }
            return .id3Tag(tag)
        } catch RemoteID3TagFetcherError.invalidHeader {
            var start = header.withLock { $0 } ?? Data()
            if start.isEmpty {
                // Another caller's shared read saw the header first.
                start = (try? await client.rangeData(for: url, range: 0..<10, profile: profile).0) ?? Data()
            }
            // MPEG-4 files begin with a box whose type sits at bytes 4..<8.
            if start.count >= 8, start.subdata(in: 4..<8) == Data("ftyp".utf8) {
                return .mpeg4
            }
            return .untaggedAudio
        }
    }

    /// Fetches only the ID3 header and declared tag bytes through the app's
    /// credential-aware range client.
    private static func fetchID3Tag(
        maxSize: Int,
        fetchRange: @Sendable (Range<Int>) async throws -> Data
    ) async throws -> Data {
        let header = try await fetchRange(0..<10)
        guard header.count == 10 else { throw PodcastRangeRequestError.rangeNotSatisfied }
        guard header.starts(with: [0x49, 0x44, 0x33]) else {
            throw RemoteID3TagFetcherError.invalidHeader
        }

        let tagBodySize = (6..<10).reduce(0) { ($0 << 7) | Int(header[$1] & 0x7F) }
        let totalSize = 10 + tagBodySize
        guard totalSize <= maxSize else {
            throw RemoteID3TagFetcherError.tagTooLarge(totalSize)
        }

        let tag = try await fetchRange(0..<totalSize)
        guard tag.count == totalSize else { throw PodcastRangeRequestError.rangeNotSatisfied }
        return tag
    }

    static func record(_ outcome: RemoteChapterOutcome, for url: URL) async {
        logger.info("Remote chapters: \(outcome.summary, privacy: .public)")
        await RemoteChapterDiagnostics.shared.record(outcome, for: url)
    }
}

/// Shares one in-flight tag read between the player and background extraction
/// for the same episode, and keeps a successful tag for a few minutes.
private actor RemoteID3TagCache {
    private struct Entry {
        let data: Data
        let fetchedAt: Date
    }

    private var inFlight: [String: Task<Data, Error>] = [:]
    private var completed: [String: Entry] = [:]
    private let lifetime: TimeInterval = 5 * 60
    private let maximumEntries = 4

    func cachedTag(for url: URL, profile: PodcastAccessProfile?) -> Data? {
        let key = Self.key(url, profile)
        guard let entry = completed[key], Date().timeIntervalSince(entry.fetchedAt) < lifetime else {
            completed[key] = nil
            return nil
        }
        return entry.data
    }

    func tag(
        for url: URL,
        profile: PodcastAccessProfile?,
        fetch: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        let key = Self.key(url, profile)
        if let task = inFlight[key] {
            return try await task.value
        }
        let task = Task { try await fetch() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let data = try await task.value
        if completed.count >= maximumEntries,
           let oldest = completed.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
            completed[oldest] = nil
        }
        completed[key] = Entry(data: data, fetchedAt: Date())
        return data
    }

    private static func key(_ url: URL, _ profile: PodcastAccessProfile?) -> String {
        url.absoluteString + "|" + (profile?.id ?? "public")
    }
}

/// The latest outcome per episode for the DEBUG chapter tools. Keys are hashes,
/// so no episode or feed URL is held here in readable form.
actor RemoteChapterDiagnostics {
    static let shared = RemoteChapterDiagnostics()

    private var outcomes: [String: RemoteChapterOutcome] = [:]
    private var order: [String] = []
    private let maximumEntries = 50

    func record(_ outcome: RemoteChapterOutcome, for url: URL) {
        let key = Self.key(url)
        if outcomes[key] == nil {
            order.append(key)
            if order.count > maximumEntries {
                outcomes[order.removeFirst()] = nil
            }
        }
        outcomes[key] = outcome
    }

    func latest(for url: URL) -> RemoteChapterOutcome? {
        outcomes[Self.key(url)]
    }

    private static func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
