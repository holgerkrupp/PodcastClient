import CryptoKit
import Foundation

/// A bounded on-disk cache for artwork that has already been prepared for display.
///
/// `URLCache` remains responsible for HTTP responses. This cache stores the much
/// smaller, downsampled images that the UI actually consumes so a cold launch does
/// not need to decode an oversized source image or recreate a blurred background.
actor ArtworkDiskCache {
    enum Variant: Sendable {
        case image(maxPixelSize: CGFloat)
        case blurred(radius: CGFloat, maxPixelSize: CGFloat)

        fileprivate var identifier: String {
            switch self {
            case .image(let maxPixelSize):
                return "image-max-\(Int(maxPixelSize.rounded(.up)))"
            case .blurred(let radius, let maxPixelSize):
                return "blur-\(Int(radius.rounded()))-max-\(Int(maxPixelSize.rounded(.up)))"
            }
        }
    }

    static let shared = ArtworkDiskCache()

    private static let cacheVersion = 1
    private static let defaultByteLimit: Int64 = 160 * 1_024 * 1_024
    private static let pruneTargetRatio = 0.85

    private let directoryURL: URL?
    private let byteLimit: Int64
    private let pruneInterval: Int
    private var writesSinceLastPrune = 0
    private var hasPrunedThisSession = false

    init(
        directoryURL: URL? = ArtworkDiskCache.defaultDirectoryURL(),
        byteLimit: Int64 = ArtworkDiskCache.defaultByteLimit,
        pruneInterval: Int = 24
    ) {
        self.directoryURL = directoryURL
        self.byteLimit = max(byteLimit, 0)
        self.pruneInterval = max(pruneInterval, 1)
    }

    func cachedData(for sourceURL: URL, variant: Variant) -> Data? {
        guard let fileURL = fileURL(for: sourceURL, variant: variant),
              let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            return nil
        }

        touchIfNeeded(fileURL)
        return data
    }

    func store(_ data: Data, for sourceURL: URL, variant: Variant) {
        guard data.isEmpty == false,
              Int64(data.count) <= byteLimit,
              let directoryURL,
              let fileURL = fileURL(for: sourceURL, variant: variant) else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic])
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableFileURL = fileURL
            try? mutableFileURL.setResourceValues(resourceValues)
        } catch {
            return
        }

        writesSinceLastPrune += 1
        if hasPrunedThisSession == false || writesSinceLastPrune >= pruneInterval {
            hasPrunedThisSession = true
            writesSinceLastPrune = 0
            pruneIfNeeded()
        }
    }

    func removeAll() {
        guard let directoryURL else { return }
        try? FileManager.default.removeItem(at: directoryURL)
        writesSinceLastPrune = 0
        hasPrunedThisSession = false
    }

    nonisolated static func cacheKey(for sourceURL: URL, variant: Variant) -> String {
        let input = "v\(cacheVersion)|\(variant.identifier)|\(sourceURL.absoluteString)"
        return SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private nonisolated static func defaultDirectoryURL() -> URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ArtworkImages-v\(cacheVersion)", isDirectory: true)
    }

    private func fileURL(for sourceURL: URL, variant: Variant) -> URL? {
        directoryURL?.appendingPathComponent(
            Self.cacheKey(for: sourceURL, variant: variant),
            isDirectory: false
        )
    }

    private func touchIfNeeded(_ fileURL: URL) {
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        if let lastAccess = values?.contentModificationDate,
           Date().timeIntervalSince(lastAccess) < 3_600 {
            return
        }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fileURL.path
        )
    }

    private func pruneIfNeeded() {
        guard byteLimit > 0, let directoryURL else { return }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let entries: [(url: URL, bytes: Int64, date: Date)] = files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                return nil
            }
            return (
                url,
                Int64(values.fileSize ?? 0),
                values.contentModificationDate ?? .distantPast
            )
        }

        var totalBytes = entries.reduce(Int64.zero) { $0 + $1.bytes }
        guard totalBytes > byteLimit else { return }

        let targetBytes = Int64(Double(byteLimit) * Self.pruneTargetRatio)
        for entry in entries.sorted(by: { $0.date < $1.date }) where totalBytes > targetBytes {
            do {
                try FileManager.default.removeItem(at: entry.url)
                totalBytes -= entry.bytes
            } catch {
                continue
            }
        }
    }
}
