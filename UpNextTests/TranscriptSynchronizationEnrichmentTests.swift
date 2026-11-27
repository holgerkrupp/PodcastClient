import CoreMedia
import XCTest
@testable import UpNext

final class TranscriptSynchronizationEnrichmentTests: XCTestCase {
    private let lineID = UUID()
    private let text = " 🦉 Café, cedar amber lantern."

    private func index(native: [TranscriptTimedSpan] = []) throws -> TranscriptSynchronizationWordIndex {
        try XCTUnwrap(TranscriptSynchronizationWordIndex(candidates: [
            .init(id: UUID().uuidString, transcriptTime: 0, text: "We’re on-air.", source: .publisher),
            .init(id: lineID.uuidString, transcriptTime: 100, text: text, source: .publisher,
                  endTime: 104, timedSpans: native)
        ]))
    }

    private func result(_ text: String, spans: [TranscriptTimedSpan]) -> AITranscripts.TimedResult {
        .init(range: CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600)),
              text: text, timedSpans: spans)
    }

    private func recognize(_ words: [String]) -> AITranscripts.TimedResult {
        var offset = 0
        let spans = words.enumerated().map { index, word in
            defer { offset += word.utf16.count + 1 }
            return TranscriptTimedSpan(location: offset, length: word.utf16.count,
                                       startTime: Double(index), endTime: Double(index + 1))
        }
        return result(words.joined(separator: " "), spans: spans)
    }

    private func map(_ index: TranscriptSynchronizationWordIndex, _ speech: AITranscripts.TimedResult,
                     language: String = "en") -> [PublisherTranscriptTimingOverlay.Mapping] {
        index.mappings(results: [speech], sample: 250..<254, expected: 102,
                       publisherLanguage: language, speechLanguage: "en-US")
    }

    func testVerifiedWordsKeepOriginalLineOffsetsAndStableDocumentIndices() async throws {
        let native = TranscriptTimedSpan(location: (text as NSString).range(of: "cedar").location,
                                        length: 5, startTime: 101, endTime: 102)
        let mappings = map(try index(native: [native]), recognize(["café", "cedar", "amber", "lantern"]))
        XCTAssertEqual(mappings.map(\.tokenIndex), [3, 5, 6])
        XCTAssertEqual(Set(mappings.map(\.lineID)), [lineID])
        XCTAssertEqual(mappings.map { (text as NSString).substring(with: NSRange(location: $0.location, length: $0.length)) },
                       ["Café", "amber", "lantern"])
        XCTAssertEqual(mappings.map(\.audioStart), [250, 252, 253])
        XCTAssertEqual(mappings.map(\.audioEnd), [251, 253, 254])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PublisherTranscriptTimingOverlayCache(cacheDirectory: directory)
        let key = PublisherTranscriptTimingOverlay.Key(episodeID: "episode", mediaFingerprint: "audio", transcriptRevision: "revision")
        try await cache.merge(mappings, for: key)
        let stored = try await cache.mappings(for: key, in: 252..<254)
        XCTAssertEqual(stored, Array(mappings.suffix(2)))
        let differentAudio = PublisherTranscriptTimingOverlay.Key(episodeID: key.episodeID, mediaFingerprint: "other",
                                                                  transcriptRevision: key.transcriptRevision)
        let stale = try await cache.mappings(for: differentAudio, in: 252..<254)
        XCTAssertTrue(stale.isEmpty)
    }

    func testInsertedSpeechAndUnsupportedLanguageAddNoWords() throws {
        let index = try index()
        XCTAssertTrue(map(index, recognize(["sponsor", "discount", "today"])).isEmpty)
        XCTAssertTrue(map(index, recognize(["café", "cedar", "amber"]), language: "fr").isEmpty)
    }

    func testUntimedPhraseAndOutOfSampleSpansNeverBecomeWordTimes() throws {
        let index = try index()
        let phrase = "café cedar amber"
        XCTAssertTrue(map(index, result(phrase, spans: [])).isEmpty)
        XCTAssertTrue(map(index, result(phrase, spans: [
            .init(location: 0, length: phrase.utf16.count, startTime: 0, endTime: 2)
        ])).isEmpty)
        let speech = recognize(["café", "cedar", "amber"])
        XCTAssertTrue(index.mappings(results: [speech], sample: 80..<82, expected: 101,
                                     publisherLanguage: "en", speechLanguage: "en").isEmpty)
    }

    func testCoverageRequiresTheWholeClampedSampleIncludingItsInterior() throws {
        let window = TranscriptAudioSampler.window(center: 253, duration: 7, mediaDuration: 254)
        XCTAssertEqual(window, 247..<254)
        XCTAssertEqual(TranscriptAudioSampler.window(center: 0, duration: 7, mediaDuration: 3), 0..<3)
        let words = map(try index(), recognize(["café", "cedar", "amber", "lantern"]))
        XCTAssertTrue(TranscriptSynchronizationWordIndex.covers(250..<254, mappings: words))
        XCTAssertFalse(TranscriptSynchronizationWordIndex.covers(window, mappings: words))
        XCTAssertFalse(TranscriptSynchronizationWordIndex.covers(250..<254, mappings: [words.first!, words.last!]))
    }

    func testSeekAndIdentityChangesSupersedeActiveWindow() {
        func request(_ time: Double, episode: String = "episode", revision: String = "one", size: Int = 100)
            -> TranscriptSynchronizationService.PlaybackRequest {
            .init(episodeID: episode, mediaURL: URL(fileURLWithPath: "/sample"), size: size,
                  modifiedAt: nil, revision: revision, audioTime: time)
        }
        let current = request(1_900)
        XCTAssertTrue(request(1_915).canReuse(current, running: true))
        XCTAssertFalse(request(1_915).canReuse(current, running: false))
        for replacement in [request(100), request(3_700), request(1_900, episode: "next"),
                            request(1_900, revision: "two"), request(1_900, size: 200)] {
            XCTAssertFalse(replacement.canReuse(current, running: true))
        }
    }
}
