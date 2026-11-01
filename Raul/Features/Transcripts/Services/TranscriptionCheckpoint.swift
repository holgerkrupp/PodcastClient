import CryptoKit
import Foundation

/// Lets a deferred automatic transcription continue instead of starting over.
///
/// Automatic runs are cancelled whenever playback starts or a background window
/// ends, and a long episode can take over an hour at the throttled rate. Without
/// this, every cancellation threw away all the analyzer work done so far.
///
/// The file is one JSON object per line, so a save only appends the new segments
/// and a torn last line from a killed process costs just that segment. It lives
/// in Caches: losing it only means transcribing from the start.
struct TranscriptionCheckpoint: Sendable {
    struct Segment: Codable, Equatable, Sendable {
        let start: Double
        let end: Double
        let text: String
    }

    static let maximumAge: TimeInterval = 60 * 60 * 24 * 7

    let fileURL: URL

    /// The identity covers everything that changes the output, so a replaced
    /// download or a changed snippet setting starts fresh.
    init?(
        mediaURL: URL,
        localeIdentifier: String,
        maxSnippetDurationSeconds: Double,
        maxWordsPerSnippet: Int,
        directory: URL = TranscriptionCheckpoint.defaultDirectory
    ) {
        guard let values = try? mediaURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modifiedAt = values.contentModificationDate else { return nil }
        let identity = [
            mediaURL.lastPathComponent,
            String(size),
            String(modifiedAt.timeIntervalSince1970),
            localeIdentifier,
            String(maxSnippetDurationSeconds),
            String(maxWordsPerSnippet)
        ].joined(separator: "|")
        let name = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        fileURL = directory.appendingPathComponent(name + ".jsonl")
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranscriptionCheckpoints", isDirectory: true)
    }

    /// The saved segments, in order. Anything unreadable ends the list, because
    /// resuming after a hole would silently lose that part of the transcript.
    func load() -> [Segment] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        var segments: [Segment] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let segment = try? decoder.decode(Segment.self, from: line) else { break }
            segments.append(segment)
        }
        return segments
    }

    func append(_ segments: [Segment]) {
        guard segments.isEmpty == false else { return }
        let encoder = JSONEncoder()
        var data = Data()
        for segment in segments {
            guard let encoded = try? encoder.encode(segment) else { return }
            data.append(encoded)
            data.append(UInt8(ascii: "\n"))
        }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: fileURL.path) == false {
                try data.write(to: fileURL)
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            AppDiagnostics.log("transcription_checkpoint_write_failed")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Removes checkpoints of episodes that were deleted or never resumed.
    static func removeStale(in directory: URL = defaultDirectory, now: Date = Date()) {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in urls {
            guard let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
                  now.timeIntervalSince(modifiedAt) > maximumAge else { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}
