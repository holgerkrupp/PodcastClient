import Foundation
import XCTest
@testable import UpNext

final class ArtworkDiskCacheTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtworkDiskCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testStoresVariantsSeparatelyAndReadsThemBack() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = ArtworkDiskCache(
            directoryURL: directory,
            byteLimit: 1_024,
            pruneInterval: 10
        )
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/cover.jpg"))
        let imageData = Data([1, 2, 3])
        let blurredData = Data([4, 5, 6])

        await cache.store(imageData, for: sourceURL, variant: .image(maxPixelSize: 512))
        await cache.store(
            blurredData,
            for: sourceURL,
            variant: .blurred(radius: 8, maxPixelSize: 512)
        )

        let storedImage = await cache.cachedData(
            for: sourceURL,
            variant: .image(maxPixelSize: 512)
        )
        let storedBlur = await cache.cachedData(
            for: sourceURL,
            variant: .blurred(radius: 8, maxPixelSize: 512)
        )
        XCTAssertEqual(storedImage, imageData)
        XCTAssertEqual(storedBlur, blurredData)
    }

    func testCacheKeyIncludesDisplayVariant() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/cover.jpg"))

        let small = ArtworkDiskCache.cacheKey(
            for: sourceURL,
            variant: .image(maxPixelSize: 256)
        )
        let large = ArtworkDiskCache.cacheKey(
            for: sourceURL,
            variant: .image(maxPixelSize: 1_400)
        )
        let blurred = ArtworkDiskCache.cacheKey(
            for: sourceURL,
            variant: .blurred(radius: 8, maxPixelSize: 256)
        )

        XCTAssertNotEqual(small, large)
        XCTAssertNotEqual(small, blurred)
        XCTAssertEqual(small.count, 64)
    }

    func testPrunesLeastRecentlyUsedFilesWhenOverLimit() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = ArtworkDiskCache(
            directoryURL: directory,
            byteLimit: 100,
            pruneInterval: 1
        )
        let firstURL = try XCTUnwrap(URL(string: "https://example.com/first.jpg"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/second.jpg"))

        await cache.store(
            Data(repeating: 1, count: 60),
            for: firstURL,
            variant: .image(maxPixelSize: 512)
        )
        await cache.store(
            Data(repeating: 2, count: 60),
            for: secondURL,
            variant: .image(maxPixelSize: 512)
        )

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        let totalBytes = try files.reduce(Int64.zero) { partialResult, fileURL in
            let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return partialResult + Int64(size)
        }

        XCTAssertLessThanOrEqual(totalBytes, 85)
        XCTAssertEqual(files.count, 1)
    }
}
