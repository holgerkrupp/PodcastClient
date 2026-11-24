import XCTest
@testable import UpNext

final class PublisherTranscriptWordMatcherTests: XCTestCase {
    private typealias Matcher = PublisherTranscriptWordMatcher
    private typealias Word = PublisherTranscriptWordMatcher.SpeechWord

    private func segment(_ text: String, at time: Double = 20,
                         spans: [TranscriptTimedSpan] = []) -> TranscriptSegment {
        let id = UUID()
        return TranscriptSegment(id: id, speaker: nil, text: text, startTime: time,
                                 endTime: time + 4, lineIDs: [id], timedSpans: spans)
    }

    private func words(_ text: String, at start: Double = 120) -> [Word] {
        text.split(separator: " ").enumerated().map {
            let time = start + Double($0.offset) * 0.5
            return Word(text: String($0.element), audioStart: time, audioEnd: time + 0.3)
        }
    }

    private func match(_ words: [Word], _ segments: [TranscriptSegment], near time: Double = 20,
                       publisher: String = "en", speech: String = "en-US") -> [PublisherWordTimingMatch] {
        Matcher.match(words: words, segments: segments, expectedTranscriptTime: time,
                      publisherLanguage: publisher, speechLanguage: speech)
    }

    private func excerpts(_ matches: [PublisherWordTimingMatch], in segment: TranscriptSegment) -> [String] {
        matches.map {
            XCTAssertEqual($0.segmentID, segment.id)
            return (segment.text as NSString).substring(with: NSRange($0.textRange))
        }
    }

    func testOriginalUTF16RangesCasePunctuationAndSpeakerLabel() {
        let text = "🎧 HOST: «Cafe\u{301}, naïve… ROCKET!»"
        let cue = segment(text)
        let observed = words("CAFÉ naïve rocket.")
        let result = match(observed, [cue])
        XCTAssertEqual(excerpts(result, in: cue).map { Array($0.utf8) },
                       ["Cafe\u{301}", "naïve", "ROCKET"].map { Array($0.utf8) })
        XCTAssertEqual(result.first?.textRange.lowerBound, (text as NSString).range(of: "Cafe\u{301}").location)
        XCTAssertEqual(result.map(\.audioStart), observed.map(\.audioStart))
        XCTAssertEqual(result.map(\.audioEnd), observed.map(\.audioEnd))
    }

    func testCompoundsAndExpandedContractionsUseWholeObservedIntervals() {
        let cue = segment("We don’t repair MacBook keyboards")
        let observed = words("we do not repair Mac Book keyboards")
        let result = match(observed, [cue])
        XCTAssertEqual(excerpts(result, in: cue), ["We", "don’t", "repair", "MacBook", "keyboards"])
        XCTAssertEqual(result.map(\.audioStart), [0, 1, 3, 4, 6].map { observed[$0].audioStart })
        XCTAssertEqual(result.map(\.audioEnd), [0, 2, 3, 5, 6].map { observed[$0].audioEnd })

        let split = segment("We do not repair Mac Book keyboards")
        let reverse = words("we don't repair MacBook keyboards")
        let mapped = match(reverse, [split])
        XCTAssertEqual(excerpts(mapped, in: split), ["We", "do not", "repair", "Mac Book", "keyboards"])
        XCTAssertEqual(mapped.map(\.audioEnd), reverse.map(\.audioEnd))
    }

    func testFillerOmittedWordsTypoAndRecognitionErrorAreLeftUnmapped() {
        let cue = segment("Bright red foxes cross the quiet forrest before sunrise")
        let observed = words("bright um foxes cross a quiet forest before sunrise")
        let result = match(observed, [cue])
        XCTAssertEqual(excerpts(result, in: cue), ["Bright", "foxes", "cross", "quiet", "before", "sunrise"])
        XCTAssertEqual(result.map(\.audioStart), [0, 2, 3, 5, 7, 8].map { observed[$0].audioStart })
    }

    func testRepeatedPassagesCommonPhrasesAndAmbiguousSingleWords() {
        let phrase = "silver rocket launch"
        XCTAssertTrue(match(words(phrase), [segment(phrase), segment(phrase, at: 24)]).isEmpty)
        XCTAssertTrue(match(words(phrase), [segment(phrase + " " + phrase)]).isEmpty)
        XCTAssertTrue(match(words("and then you are here"), [segment("and then you are here")]).isEmpty)

        let repeated = segment("Bright red red foxes sprint")
        let unique = match(words("bright red foxes sprint"), [repeated])
        XCTAssertEqual(excerpts(unique, in: repeated), ["Bright", "foxes", "sprint"])
        let once = segment("Bright red foxes sprint")
        XCTAssertEqual(excerpts(match(words("bright red red foxes sprint"), [once]), in: once),
                       ["Bright", "foxes", "sprint"])
    }

    func testAdGapDoesNotAcquireOrStretchTiming() {
        let cue = segment("Silver rockets launch purple planets sparkle")
        let before = words("silver rockets launch")
        let ad = words("limited offer purple today", at: 140)
        let after = words("purple planets sparkle", at: 230)
        let result = match(before + ad + after, [cue])
        // Either spoken "purple" could account for the publisher word.
        XCTAssertFalse(result.contains { $0.audioEnd > before.last!.audioEnd && $0.audioStart < after[0].audioStart })
        XCTAssertTrue(result.contains { $0.audioEnd == before.last!.audioEnd })
        XCTAssertFalse(excerpts(result, in: cue).contains("purple"))

        let complete = match(before + words("limited offer today", at: 140) + after, [cue])
        XCTAssertEqual(complete.map(\.audioStart), (before + after).map(\.audioStart))
        XCTAssertEqual(complete.map(\.audioEnd), (before + after).map(\.audioEnd))
    }

    func testNativeWordRangesWinWhileCueLevelSpansAllowEnrichment() {
        let text = "Silver rockets launch tonight"
        let cue = segment(text, spans: [
            TranscriptTimedSpan(location: 0, length: text.utf16.count, startTime: 20, endTime: 25, cueLevel: true),
            TranscriptTimedSpan(location: 7, length: 7, startTime: 21, endTime: 22)
        ])
        XCTAssertEqual(excerpts(match(words(text), [cue]), in: cue), ["Silver", "launch", "tonight"])
    }

    func testPassageSpansSegmentsAndSearchStaysBounded() {
        let first = segment("Silver rockets", at: 175)
        let second = segment("launch tonight", at: 179)
        let observed = words("silver rockets launch tonight")
        let mapped = match(observed, [first, second], near: 20)
        XCTAssertEqual(mapped.map(\.segmentID), [first.id, first.id, second.id, second.id])
        XCTAssertEqual(mapped.map(\.textRange), [0..<6, 7..<14, 0..<6, 7..<14])
        XCTAssertTrue(match(observed, [first, second], near: 400).isEmpty)
        let crowded = segment(String(repeating: "x ", count: 1_025) + "silver rockets launch tonight")
        XCTAssertTrue(match(observed, [crowded]).isEmpty)
        XCTAssertTrue(match(Array(repeating: observed, count: 13).flatMap { $0 }, [first, second]).isEmpty)
    }

    func testLanguageAgreementAndUnsupportedLanguages() {
        let cue = segment("Über große Wälder")
        let observed = words("ÜBER große wälder")
        XCTAssertEqual(excerpts(match(observed, [cue], publisher: "de-DE", speech: "de_AT"), in: cue),
                       ["Über", "große", "Wälder"])
        XCTAssertTrue(match(observed, [cue], publisher: "de", speech: "en").isEmpty)
        XCTAssertTrue(match(observed, [cue], publisher: "ja", speech: "ja").isEmpty)
        XCTAssertTrue(match(observed, [cue], publisher: "", speech: "").isEmpty)
    }

    func testInvalidTimingAndOverlappingOrReversedAudioFailClosed() {
        let cue = segment("Silver rockets launch")
        let observed = words(cue.text)
        for invalid in [
            Word(text: "launch", audioStart: -.infinity, audioEnd: 124),
            Word(text: "launch", audioStart: 122, audioEnd: .nan),
            Word(text: "launch", audioStart: 122, audioEnd: 122),
            Word(text: "launch", audioStart: 120.6, audioEnd: 121)
        ] {
            XCTAssertTrue(match(Array(observed.prefix(2)) + [invalid], [cue]).isEmpty)
        }
        XCTAssertTrue(match(Array(observed.reversed()), [cue]).isEmpty)
        XCTAssertTrue(match(observed, [cue], near: .nan).isEmpty)
    }
}
