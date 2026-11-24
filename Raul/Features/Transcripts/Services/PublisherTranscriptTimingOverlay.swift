import CryptoKit
import Foundation

/// One bounded page of a publisher document's timing overlay. All offsets are into
/// the canonical document for this revision. The cache never needs the cue text.
struct PublisherTranscriptTimingOverlay: Codable, Sendable {
    struct Key: Codable, Hashable, Sendable {
        let episodeID: String          // Episode.stableEpisodeIdentity.key
        let mediaFingerprint: String   // TranscriptMediaFingerprint.make(for:)
        let transcriptRevision: String // TranscriptSynchronizationRevision.make(candidates:)

        fileprivate var digest: String? {
            guard !episodeID.isEmpty, !mediaFingerprint.isEmpty, !transcriptRevision.isEmpty else { return nil }
            let components = [episodeID, mediaFingerprint, transcriptRevision]
            let identity = components.map { "\($0.utf8.count):\($0)" }.joined()
            return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    struct Mapping: Codable, Equatable, Sendable {
        enum Source: String, Codable, Sendable {
            case alignedSpeech, publisherNative
        }

        /// Zero-based word index in the full publisher revision, including unmapped words.
        let tokenIndex: Int
        let lineID: UUID
        let location: Int
        let length: Int
        let audioStart: TimeInterval
        let audioEnd: TimeInterval
        let confidence: Double
        var source: Source = .alignedSpeech

        fileprivate var isUsable: Bool {
            tokenIndex >= 0 && location >= 0 && length > 0 && location <= Int.max - length
                && audioStart.isFinite && audioStart >= 0 && audioEnd.isFinite && audioEnd > audioStart
                && (0...1).contains(confidence) && (source == .publisherNative || confidence >= 0.82)
        }

        fileprivate func supersedes(_ other: Self) -> Bool {
            if source != other.source { return source == .publisherNative }
            return confidence > other.confidence
        }
    }

    static let tokensPerChunk = 128
    fileprivate var mappings: [Int: Mapping] = [:]

    fileprivate mutating func merge(_ additions: [Mapping]) -> Bool {
        var changed = false
        for mapping in additions {
            if let existing = mappings[mapping.tokenIndex], !mapping.supersedes(existing) { continue }
            mappings[mapping.tokenIndex] = mapping
            changed = true
        }
        return changed
    }
}

/// Local, disposable cache. Share one writer per directory. The small index is
/// ordered by last successful enrichment and records the audio extent of each page.
actor PublisherTranscriptTimingOverlayCache {
    typealias Key = PublisherTranscriptTimingOverlay.Key
    typealias Mapping = PublisherTranscriptTimingOverlay.Mapping
    private typealias Chunk = PublisherTranscriptTimingOverlay

    static let shared = PublisherTranscriptTimingOverlayCache()

    private struct Entry: Codable {
        let keyDigest: String
        let chunkIndex: Int
        let fileID: UUID
        let audioStart: TimeInterval
        let audioEnd: TimeInterval
    }

    private let directory: URL
    private let maximumChunks: Int
    private var needsCleanup = true
    private var indexURL: URL { directory.appendingPathComponent("index.plist") }

    init(cacheDirectory: URL = .cachesDirectory, maximumChunks: Int = 512) {
        directory = cacheDirectory.appendingPathComponent("PublisherTranscriptTimingOverlay-v1", isDirectory: true)
        self.maximumChunks = max(1, maximumChunks)
    }

    /// Returns words intersecting the half-open audio range, ordered for playback.
    func mappings(for key: Key, in range: Range<TimeInterval>) throws -> [Mapping] {
        guard !range.isEmpty, range.lowerBound.isFinite, range.upperBound.isFinite,
              let digest = key.digest else { return [] }
        var result: [Mapping] = []
        for entry in try index() where entry.keyDigest == digest
            && entry.audioStart < range.upperBound && entry.audioEnd > range.lowerBound {
            let chunk = try read(Chunk.self, from: chunkURL(entry.fileID))
            if let chunk {
                result += chunk.mappings.values.filter { $0.audioStart < range.upperBound && $0.audioEnd > range.lowerBound }
            }
        }
        return result.sorted { ($0.audioStart, $0.tokenIndex) < ($1.audioStart, $1.tokenIndex) }
    }

    func merge(_ mappings: [Mapping], for key: Key) throws {
        guard let digest = key.digest else { return }
        let pages = Dictionary(grouping: mappings.filter(\.isUsable)) { $0.tokenIndex / Chunk.tokensPerChunk }
        guard !pages.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var entries = try index()
        if needsCleanup {
            try removeUnreferencedChunks(keeping: entries)
            needsCleanup = false
        }
        var changed = false
        // If a single import exceeds capacity, retain its last document pages.
        for page in pages.keys.sorted().suffix(maximumChunks) {
            let previous = entries.firstIndex { $0.keyDigest == digest && $0.chunkIndex == page }
            var chunk = try previous.flatMap { try read(Chunk.self, from: chunkURL(entries[$0].fileID)) } ?? Chunk()
            guard chunk.merge(pages[page] ?? []) else {
                if pages.count >= maximumChunks, let previous {
                    let retained = entries.remove(at: previous)
                    entries.append(retained)
                }
                continue
            }
            let words = chunk.mappings.values
            guard let start = words.map(\.audioStart).min(), let end = words.map(\.audioEnd).max() else { continue }
            let entry = Entry(keyDigest: digest, chunkIndex: page, fileID: UUID(), audioStart: start, audioEnd: end)
            needsCleanup = true
            try write(chunk, to: chunkURL(entry.fileID))
            if let previous { entries.remove(at: previous) }
            entries.append(entry)
            changed = true
        }
        if changed {
            entries = Array(entries.suffix(maximumChunks))
            try write(entries, to: indexURL)
            try removeUnreferencedChunks(keeping: entries)
            needsCleanup = false
        }
    }

    func remove(for key: Key) throws {
        guard let digest = key.digest else { return }
        let entries = try index()
        let remaining = entries.filter { $0.keyDigest != digest }
        guard remaining.count != entries.count else { return }
        try write(remaining, to: indexURL)
        try removeUnreferencedChunks(keeping: remaining)
    }

    private func index() throws -> [Entry] { try read([Entry].self, from: indexURL) ?? [] }

    private func chunkURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("chunk")
    }

    // Write immutable chunks first, then atomically publish the index. An interrupted
    // merge leaves the old index usable. The next merge collects abandoned files.
    private func removeUnreferencedChunks(keeping entries: [Entry]) throws {
        let retained = Set(entries.map { chunkURL($0.fileID).lastPathComponent })
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "chunk" && !retained.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        do {
            return try PropertyListDecoder().decode(type, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return nil // The system can purge local cache files.
        } catch is DecodingError {
            return nil // A damaged page can be rebuilt independently.
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
