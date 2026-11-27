import XCTest
@testable import UpNext

final class TranscriptMediaFingerprintTests: XCTestCase {
    private let sample = TranscriptMediaFingerprint.boundedSampleLength

    private func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func bytes(_ count: Int, seed: UInt8 = 0) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    private func flipped(_ data: Data, at offset: Int) -> Data {
        var copy = data
        copy[offset] ^= 0xFF
        return copy
    }

    func testSameBytesProduceSameVersionedFingerprint() throws {
        let data = bytes(sample * 5)
        let first = try TranscriptMediaFingerprint.makeBounded(for: file(data))
        let second = try TranscriptMediaFingerprint.makeBounded(for: file(data))
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix(TranscriptMediaFingerprint.boundedVersionPrefix))
        XCTAssertEqual(first.count, TranscriptMediaFingerprint.boundedVersionPrefix.count + 64)
    }

    func testNeverEqualsFullFileDigest() throws {
        for count in [1, sample * 2, sample * 5] {
            let url = try file(bytes(count))
            XCTAssertNotEqual(try TranscriptMediaFingerprint.makeBounded(for: url),
                              try TranscriptMediaFingerprint.make(for: url))
        }
    }

    func testHeadMiddleAndTailChangesProduceDifferentFingerprints() throws {
        let size = sample * 5 + 17
        let data = bytes(size)
        let base = try TranscriptMediaFingerprint.makeBounded(for: file(data))
        let middleStart = (size - sample) / 2
        for offset in [0, sample - 1, middleStart, middleStart + sample - 1, size - sample, size - 1] {
            XCTAssertNotEqual(try TranscriptMediaFingerprint.makeBounded(for: file(flipped(data, at: offset))), base,
                              "offset \(offset)")
        }
    }

    func testUnsampledBytesAreOutsideIdentityButSizeIsNot() throws {
        let data = bytes(sample * 5)
        let base = try TranscriptMediaFingerprint.makeBounded(for: file(data))
        // Between the first and middle windows: intentionally not read.
        XCTAssertEqual(try TranscriptMediaFingerprint.makeBounded(for: file(flipped(data, at: sample + 10))), base)
        XCTAssertNotEqual(try TranscriptMediaFingerprint.makeBounded(for: file(data + Data([0]))), base)
    }

    func testSmallFilesAreHashedCompletely() throws {
        for size in [1, 100, sample, sample * 3 - 1, sample * 3] {
            let data = bytes(size, seed: 7)
            let base = try TranscriptMediaFingerprint.makeBounded(for: file(data))
            for offset in Set([0, size / 2, size - 1]) {
                XCTAssertNotEqual(try TranscriptMediaFingerprint.makeBounded(for: file(flipped(data, at: offset))), base,
                                  "size \(size) offset \(offset)")
            }
        }
    }

    func testEmptyAndMissingFilesThrow() throws {
        let empty = try file(Data())
        XCTAssertThrowsError(try TranscriptMediaFingerprint.makeBounded(for: empty))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try TranscriptMediaFingerprint.makeBounded(for: missing))
    }
}
