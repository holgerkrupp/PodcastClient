import XCTest
@testable import UpNext

@MainActor
final class PublisherTranscriptTimingOverlayTests: XCTestCase {
    private typealias Cache = PublisherTranscriptTimingOverlayCache
    private typealias Mapping = PublisherTranscriptTimingOverlay.Mapping
    private let key = Cache.Key(episodeID: "episode", mediaFingerprint: "media", transcriptRevision: "revision")
    private let lineID = UUID()

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func word(_ index: Int, at time: Double, confidence: Double = 0.9,
                      source: Mapping.Source = .alignedSpeech) -> Mapping {
        Mapping(tokenIndex: index, lineID: lineID, location: index * 2, length: 1,
                audioStart: time, audioEnd: time + 1, confidence: confidence, source: source)
    }

    private func chunkFiles(in root: URL) throws -> Set<URL> {
        let directory = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.hasDirectoryPath })
        return Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "chunk" })
    }

    func testRelaunchAndAllThreeIdentityComponents() async throws {
        let root = try directory()
        let original = Cache(cacheDirectory: root)
        let mapping = word(0, at: 10)
        try await original.merge([mapping], for: key)
        let reopened = Cache(cacheDirectory: root)
        let restored = try await reopened.mappings(for: key, in: 10..<11)
        XCTAssertEqual(restored, [mapping])
        for mismatch in [
            Cache.Key(episodeID: "other", mediaFingerprint: "media", transcriptRevision: "revision"),
            .init(episodeID: "episode", mediaFingerprint: "new", transcriptRevision: "revision"),
            .init(episodeID: "episode", mediaFingerprint: "media", transcriptRevision: "new")
        ] {
            let result = try await reopened.mappings(for: mismatch, in: 10..<11)
            XCTAssertTrue(result.isEmpty)
        }
    }

    func testPartialMergeCorrectionNativePrecedenceAndIdempotence() async throws {
        let root = try directory()
        let cache = Cache(cacheDirectory: root)
        let corrected = word(0, at: 125, confidence: 0.96)
        let native = word(1, at: 126, confidence: 0.86, source: .publisherNative)
        try await cache.merge([word(0, at: 1), word(1, at: 2, confidence: 1)], for: key)
        try await cache.merge([corrected, native], for: key)
        let files = try chunkFiles(in: root)
        try await cache.merge([corrected, native, word(0, at: 50), word(0, at: 60, confidence: 0.96),
                               word(1, at: 4, confidence: 1), word(2, at: 5, confidence: 0.5)], for: key)
        XCTAssertEqual(try chunkFiles(in: root), files)
        let oldRange = try await cache.mappings(for: key, in: 0..<125)
        let newRange = try await cache.mappings(for: key, in: 125..<130)
        XCTAssertTrue(oldRange.isEmpty)
        XCTAssertEqual(newRange, [corrected, native])
    }

    func testRangeReadsSkipUnrelatedChunkAndUseHalfOpenOverlap() async throws {
        let root = try directory()
        let cache = Cache(cacheDirectory: root)
        let far = word(128, at: 400)
        try await cache.merge([far], for: key)
        let farFile = try XCTUnwrap(chunkFiles(in: root).first)
        let crossing = word(0, at: 59.5)
        try await cache.merge([word(1, at: 59), crossing, word(2, at: 61)], for: key)

        // Make accidental reads of the distant chunk fail, including after relaunch.
        try FileManager.default.removeItem(at: farFile)
        try FileManager.default.createDirectory(at: farFile, withIntermediateDirectories: false)
        let reopened = Cache(cacheDirectory: root)
        let words = try await reopened.mappings(for: key, in: 60..<61)
        XCTAssertEqual(words, [crossing])
    }

    func testLargeImportEvictsWholeChunksAndOnlyTouchesOverlayFiles() async throws {
        let root = try directory()
        let transcript = root.appendingPathComponent("publisher.vtt")
        let document = Data("WEBVTT\n".utf8)
        try document.write(to: transcript)
        let cache = Cache(cacheDirectory: root, maximumChunks: 3)
        let pageSize = PublisherTranscriptTimingOverlay.tokensPerChunk
        let count = pageSize * 40
        try await cache.merge((0..<count).map { word($0, at: Double($0)) }, for: key)
        XCTAssertEqual(try chunkFiles(in: root).count, 3)
        let retained = try await cache.mappings(for: key, in: 0..<Double(count))
        XCTAssertEqual(retained.map(\.tokenIndex), Array((count - 3 * pageSize)..<count))

        let secondKey = Cache.Key(episodeID: "second", mediaFingerprint: "media", transcriptRevision: "revision")
        try await cache.merge([word(0, at: 0)], for: secondKey)
        let afterEviction = try await cache.mappings(for: key, in: 0..<Double(count))
        XCTAssertEqual(afterEviction.count, 2 * pageSize)
        try await cache.remove(for: key)
        XCTAssertEqual(try chunkFiles(in: root).count, 1)
        let other = try await cache.mappings(for: secondKey, in: 0..<1)
        XCTAssertEqual(other, [word(0, at: 0)])
        XCTAssertEqual(try Data(contentsOf: transcript), document)
    }

    func testInvalidEvidenceAndMissingChunkAreRecoverable() async throws {
        let root = try directory()
        let cache = Cache(cacheDirectory: root)
        let good = word(0, at: 12)
        try await cache.merge([word(1, at: .nan), word(2, at: -1), word(3, at: 0, confidence: .infinity),
                               word(-1, at: 2), good], for: key)
        let valid = try await cache.mappings(for: key, in: 0..<20)
        XCTAssertEqual(valid, [good])
        try FileManager.default.removeItem(at: XCTUnwrap(chunkFiles(in: root).first))
        let purged = try await cache.mappings(for: key, in: 0..<20)
        XCTAssertTrue(purged.isEmpty)
        try await cache.merge([good], for: key)
        let recovered = try await cache.mappings(for: key, in: 0..<20)
        XCTAssertEqual(recovered, [good])
    }
}
