import AVFoundation
import Foundation
import ImageIO
import mp3ChapterReader
#if canImport(UIKit)
import UIKit
#endif

/// Extracts artwork only from an already local, regular media file. MP3 reads
/// are limited to a bounded ID3 prefix; M4A/MP4 uses AVFoundation metadata.
actor EmbeddedAudioArtworkService {
    static let shared = EmbeddedAudioArtworkService()
    static let maximumID3TagBytes = 16 * 1024 * 1024
    static let maximumArtworkBytes = 20 * 1024 * 1024

    nonisolated(unsafe) private static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 32
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func thumbnail(for fileURL: URL, maxPixelSize: CGFloat = ImageLoaderAndCache.defaultMaxPixelSize) async -> UIImage? {
        guard let fingerprint = Self.fingerprint(for: fileURL) else { return nil }
        let key = "\(fingerprint)|max:\(Int(maxPixelSize.rounded(.up)))"
        if let cached = Self.thumbnailCache.object(forKey: key as NSString) { return cached }
        if let task = inFlight[key] { return await task.value }

        let task = Task<UIImage?, Never>(priority: .utility) {
            guard let data = await Self.readArtworkData(from: fileURL),
                  data.count <= Self.maximumArtworkBytes else { return nil }
            return await Task.detached(priority: .utility) {
                ImageLoaderAndCache.makeUIImage(from: data, maxPixelSize: maxPixelSize)
            }.value
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            Self.thumbnailCache.setObject(
                image,
                forKey: key as NSString,
                cost: SharedImageRepository.memoryCost(for: image)
            )
        }
        return image
    }

    /// Shared by sideloaded metadata import and player fallback.
    nonisolated static func artworkData(from fileURL: URL, includeChapterArtwork: Bool = false) async -> Data? {
        await readArtworkData(from: fileURL, includeChapterArtwork: includeChapterArtwork)
    }

    private nonisolated static func readArtworkData(from fileURL: URL, includeChapterArtwork: Bool = false) async -> Data? {
        guard fileURL.isFileURL,
              let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isReadable == true,
              (values.fileSize ?? 0) > 0 else { return nil }

        switch fileURL.pathExtension.lowercased() {
        case "mp3":
            return await Task.detached(priority: .utility) {
                readMP3Artwork(from: fileURL, fileSize: values.fileSize ?? 0, includeChapterArtwork: includeChapterArtwork)
            }.value
        case "aac", "aif", "aiff", "caf", "m4a", "m4b", "m4p", "m4r", "mp4", "m4v", "mov", "wav":
            return await readContainerArtwork(from: fileURL)
        default:
            return nil
        }
    }

    private nonisolated static func readMP3Artwork(
        from fileURL: URL,
        fileSize: Int,
        includeChapterArtwork: Bool
    ) -> Data? {
        guard fileSize >= 10,
              let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 10),
              header.count == 10,
              header.prefix(3) == Data("ID3".utf8) else { return nil }

        let sizeBytes = Array(header[6..<10])
        guard sizeBytes.allSatisfy({ $0 & 0x80 == 0 }) else { return nil }
        let tagSize = (Int(sizeBytes[0]) << 21) | (Int(sizeBytes[1]) << 14) | (Int(sizeBytes[2]) << 7) | Int(sizeBytes[3])
        let footerSize = header[5] & 0x10 == 0 ? 0 : 10
        let totalSize = 10 + tagSize + footerSize
        guard tagSize > 0,
              totalSize <= maximumID3TagBytes,
              totalSize <= fileSize,
              let remainder = try? handle.read(upToCount: totalSize - 10),
              remainder.count == totalSize - 10 else { return nil }

        let tag = header + remainder
        guard let reader = mp3ChapterReader(fromData: tag) else { return nil }
        let frames = includeChapterArtwork
            ? pictureFrames(in: reader.frames)
            : reader.frames.compactMap { $0 as? PictureFrame }
        let preferred = frames.first(where: { $0.type == .coverFront })?.image
        let other = frames.first(where: { $0.type != .coverFront })?.image
        for candidate in [preferred, other].compactMap({ $0 }) {
            if isBoundedImage(candidate) { return candidate }
        }
        return nil
    }

    private nonisolated static func readContainerArtwork(from fileURL: URL) async -> Data? {
        let asset = AVURLAsset(url: fileURL)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for item in metadata where item.commonKey == .commonKeyArtwork {
            guard let value = try? await item.load(.value),
                  let data = value as? Data,
                  isBoundedImage(data) else { continue }
            return data
        }
        return nil
    }

    private nonisolated static func isBoundedImage(_ data: Data) -> Bool {
        guard data.isEmpty == false, data.count <= maximumArtworkBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width > 0 && height > 0 && width <= 20_000 && height <= 20_000
    }

    private nonisolated static func fingerprint(for fileURL: URL) -> String? {
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, values.isReadable == true,
              let size = values.fileSize, size > 0,
              let modified = values.contentModificationDate else { return nil }
        return "\(fileURL.standardizedFileURL.path)|\(size)|\(modified.timeIntervalSince1970)"
    }

    private nonisolated static func pictureFrames(in frames: [Frame]) -> [PictureFrame] {
        var result: [PictureFrame] = []
        for frame in frames {
            if let picture = frame as? PictureFrame {
                result.append(picture)
            } else if let chapter = frame as? ChapFrame {
                result.append(contentsOf: pictureFrames(in: chapter.frames))
            } else if let table = frame as? CTOCFrame {
                result.append(contentsOf: pictureFrames(in: table.frames))
            }
        }
        return result
    }
}
