import Foundation

struct PublisherWordTimingMatch: Equatable, Sendable {
    let segmentID: UUID
    /// UTF-16 offsets in the exact TranscriptSegment.text supplied by the caller.
    let textRange: Range<Int>
    let audioStart: TimeInterval
    let audioEnd: TimeInterval
    /// Alignment quality heuristic combining unanimous word assignment and local coverage.
    let confidence: Double
}

enum PublisherTranscriptWordMatcher {
    struct SpeechWord: Sendable {
        let text: String
        let audioStart: TimeInterval
        let audioEnd: TimeInterval
    }

    /// Supply publisher-only segments in start-time order and a short window of time-indexed
    /// Speech words in absolute media time. Pass the mapped publisher time at the playhead,
    /// or the playhead itself when a synchronization timeline is unavailable.
    static func match(
        words: [SpeechWord], segments: [TranscriptSegment], expectedTranscriptTime: TimeInterval,
        publisherLanguage: String, speechLanguage: String
    ) -> [PublisherWordTimingMatch] {
        let language = Locale(identifier: publisherLanguage).language.languageCode?.identifier
        guard let language, commonWords[language] != nil,
              language == Locale(identifier: speechLanguage).language.languageCode?.identifier,
              expectedTranscriptTime.isFinite, expectedTranscriptTime >= 0,
              (3...48).contains(words.count) else { return [] }

        var speech: [Token] = []
        var previousEnd = 0.0
        for word in words {
            guard word.audioStart.isFinite, word.audioEnd.isFinite,
                  word.audioStart >= previousEnd, word.audioEnd > word.audioStart,
                  word.text.utf8.prefix(257).count <= 256 else { return [] }
            let parts = tokens(in: word.text, language: language)
            // Speech must supply an interval for each word. Splitting a phrase-sized
            // recognition result would invent audio boundaries.
            guard parts.count == 1 else { return [] }
            var token = parts[0]
            token.joinsPrevious = !speech.isEmpty && word.audioStart - previousEnd <= 0.45
            speech.append(token)
            previousEnd = word.audioEnd
        }

        for radius in [45.0, 180.0] {
            guard let passage = passage(in: segments, near: expectedTranscriptTime, radius: radius,
                                        language: language) else { return [] }
            let alignment = align(speech, passage)
            // Widen only when the nearby text lacks evidence. A repeated passage must
            // not acquire an arbitrary winner by expanding the search.
            if alignment.score >= 3 {
                return confirmed(alignment.edges, words: words, speech: speech,
                                 passage: passage, segments: segments, language: language)
            }
        }
        return []
    }

    private struct Token {
        let key: String
        let range: Range<Int>
        var segment = 0
        var joinsPrevious = false
        var native = false
    }

    private static let wordPattern = try! NSRegularExpression(
        pattern: #"[\p{L}\p{N}][\p{L}\p{M}\p{N}]*(?:['’][\p{L}\p{M}\p{N}]+)*"#
    )

    private static func tokens(in text: String, language: String) -> [Token] {
        let source = text as NSString
        var previousEnd = 0
        return wordPattern.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap {
            let range = $0.range
            guard Range(range, in: text) != nil else { return nil }
            let word = source.substring(with: range).lowercased().replacingOccurrences(of: "’", with: "'")
            let key = language == "en" ? expanded[word] ?? word : word
            let separator = source.substring(with: NSRange(location: previousEnd, length: range.location - previousEnd))
            previousEnd = NSMaxRange(range)
            return Token(key: key, range: range.location..<previousEnd,
                         joinsPrevious: !separator.isEmpty && separator.allSatisfy { $0 == " " || $0 == "-" })
        }
    }

    // Only unambiguous expansions. In particular, "'s" and "'d" have multiple readings.
    private static let expanded = [
        "can't": "cannot", "won't": "willnot", "don't": "donot", "doesn't": "doesnot",
        "didn't": "didnot", "isn't": "isnot", "aren't": "arenot", "wasn't": "wasnot",
        "weren't": "werenot", "couldn't": "couldnot", "shouldn't": "shouldnot",
        "wouldn't": "wouldnot", "i'm": "iam", "we're": "weare", "you're": "youare",
        "they're": "theyare", "i've": "ihave", "we've": "wehave", "i'll": "iwill"
    ]

    // Only enable languages for which there is an informative-word filter and the
    // tokenizer recognizes word boundaries. Accents remain significant.
    private static let commonWords: [String: Set<String>] = [
        "en": Set("the and that this with you for are was have from but not what when where your our they them then yes okay here there now can will just".split(separator: " ").map(String.init)),
        "de": Set("der die das den dem des und oder ist sind war mit von für auf ein eine einer einen ich wir sie ihr nicht auch dann hier dort jetzt".split(separator: " ").map(String.init))
    ]

    private static func passage(in segments: [TranscriptSegment], near time: Double, radius: Double,
                                language: String) -> [Token]? {
        let lower = time - radius
        var low = 0
        var high = segments.count
        while low < high {
            let mid = low + (high - low) / 2
            if segments[mid].startTime < lower { low = mid + 1 } else { high = mid }
        }
        var index = low
        if index > 0, let end = segments[index - 1].endTime, end >= lower { index -= 1 }
        let first = index
        var passage: [Token] = []
        var ids = Set<UUID>()
        while index < segments.count {
            let segment = segments[index]
            if segment.startTime > time + radius { break }
            guard index - first < 192, segment.startTime.isFinite, segment.startTime >= 0,
                  segment.endTime.map({ $0.isFinite && $0 >= segment.startTime }) ?? true,
                  ids.insert(segment.id).inserted,
                  segment.text.utf8.prefix(4097).count <= 4096,
                  segment.timedSpans.count <= 256 else { return nil }
            let native = segment.timedSpans.compactMap { span -> Range<Int>? in
                guard span.cueLevel != true, span.startTime.isFinite, span.startTime >= 0,
                      span.endTime.isFinite, span.endTime > span.startTime,
                      span.location >= 0, span.length > 0,
                      span.location <= segment.text.utf16.count,
                      span.length <= segment.text.utf16.count - span.location,
                      Range(NSRange(location: span.location, length: span.length), in: segment.text) != nil
                else { return nil }
                return span.location..<(span.location + span.length)
            }
            let parts = tokens(in: segment.text, language: language)
            guard passage.count + parts.count <= 1024 else { return nil }
            for (offset, var token) in parts.enumerated() {
                token.segment = index
                token.joinsPrevious = offset > 0 && token.joinsPrevious
                token.native = native.contains { $0.overlaps(token.range) }
                passage.append(token)
            }
            index += 1
        }
        return passage
    }

    private struct Edge: Equatable {
        let speech: Range<Int>
        let publisher: Range<Int>
    }

    /// Longest common subsequence with single-word and two-to-one compound transitions.
    /// Trace *all* optimal predecessors. A Speech word is eligible only if every best
    /// path assigns it to exactly the same publisher range, including the option to skip.
    private static func align(_ speech: [Token], _ publisher: [Token]) -> (score: Int, edges: [Edge]) {
        guard !publisher.isEmpty else { return (0, []) }
        func pairs(_ tokens: [Token]) -> [String?] {
            tokens.indices.map { i in
                i > 0 && tokens[i].joinsPrevious ? tokens[i - 1].key + tokens[i].key : nil
            }
        }
        let speechPairs = pairs(speech), publisherPairs = pairs(publisher)
        let width = publisher.count + 1
        var score = Array(repeating: 0, count: (speech.count + 1) * width)
        var steps = Array(repeating: UInt8(0), count: score.count)
        for i in 1...speech.count {
            steps[i * width] = 1
            for j in 1...publisher.count {
                let k = i * width + j
                let dropSpeech = score[k - width], dropPublisher = score[k - 1]
                var best = max(dropSpeech, dropPublisher)
                var mask: UInt8 = (dropSpeech == best ? 1 : 0) | (dropPublisher == best ? 2 : 0)
                func consider(_ predecessor: Int, _ bit: UInt8) {
                    let value = score[predecessor] + 1
                    if value > best { best = value; mask = bit }
                    else if value == best { mask |= bit }
                }
                if speech[i - 1].key == publisher[j - 1].key { consider(k - width - 1, 4) }
                if speechPairs[i - 1] == publisher[j - 1].key { consider(k - 2 * width - 1, 8) }
                if publisherPairs[j - 1] == speech[i - 1].key { consider(k - width - 2, 16) }
                score[k] = best
                steps[k] = mask
            }
        }

        var reached = Array(repeating: false, count: score.count)
        reached[score.count - 1] = true
        var assignment = Array<Edge?>(repeating: nil, count: speech.count)
        var ambiguous = Array(repeating: false, count: speech.count)
        for i in (1...speech.count).reversed() {
            for j in (0...publisher.count).reversed() {
                let k = i * width + j
                guard reached[k] else { continue }
                let mask = steps[k]
                if mask & 1 != 0 { reached[k - width] = true; ambiguous[i - 1] = true }
                if mask & 2 != 0 { reached[k - 1] = true }
                func visit(_ audioCount: Int, _ textCount: Int) {
                    let edge = Edge(speech: (i - audioCount)..<i, publisher: (j - textCount)..<j)
                    reached[k - audioCount * width - textCount] = true
                    for word in edge.speech {
                        if let old = assignment[word], old != edge { ambiguous[word] = true }
                        assignment[word] = edge
                    }
                }
                if mask & 4 != 0 { visit(1, 1) }
                if mask & 8 != 0 { visit(2, 1) }
                if mask & 16 != 0 { visit(1, 2) }
            }
        }
        let certain = speech.indices.compactMap { i -> Edge? in
            guard let edge = assignment[i], edge.speech.lowerBound == i,
                  !edge.speech.contains(where: { ambiguous[$0] }) else { return nil }
            return edge
        }
        return (score.last ?? 0, certain)
    }

    private static func confirmed(_ edges: [Edge], words: [SpeechWord], speech: [Token],
                                  passage: [Token], segments: [TranscriptSegment],
                                  language: String) -> [PublisherWordTimingMatch] {
        let common = commonWords[language] ?? []
        var results: [PublisherWordTimingMatch] = []
        var group: [Edge] = []
        func finishGroup() {
            guard group.count >= 3, let first = group.first, let last = group.last else { return }
            let informative = Set(group.flatMap { speech[$0.speech].map(\.key) }
                .filter { $0.count > 2 && !common.contains($0) })
            let audioCoverage = Double(group.reduce(0) { $0 + $1.speech.count })
                / Double(last.speech.upperBound - first.speech.lowerBound)
            let textCoverage = Double(group.reduce(0) { $0 + $1.publisher.count })
                / Double(last.publisher.upperBound - first.publisher.lowerBound)
            let coverage = min(audioCoverage, textCoverage)
            guard informative.count >= 2, coverage >= 0.6 else { return }
            // Every emitted word already has unanimous support across optimal paths.
            // Missing or disputed neighbors reduce the confidence of that exact match.
            let confidence = (1 + coverage) / 2
            for edge in group {
                let tokens = passage[edge.publisher]
                guard !tokens.contains(where: \.native), let start = tokens.first, let end = tokens.last else { continue }
                results.append(PublisherWordTimingMatch(
                    segmentID: segments[start.segment].id, textRange: start.range.lowerBound..<end.range.upperBound,
                    audioStart: words[edge.speech.lowerBound].audioStart,
                    audioEnd: words[edge.speech.upperBound - 1].audioEnd, confidence: confidence))
            }
        }
        for edge in edges {
            if let previous = group.last {
                let before = segments[passage[previous.publisher.upperBound - 1].segment]
                let after = segments[passage[edge.publisher.lowerBound].segment]
                if edge.speech.lowerBound - previous.speech.upperBound > 2
                    || edge.publisher.lowerBound - previous.publisher.upperBound > 2
                    || words[edge.speech.lowerBound].audioStart - words[previous.speech.upperBound - 1].audioEnd > 2.5
                    || after.startTime - (before.endTime ?? before.startTime) > 8 {
                    finishGroup()
                    group.removeAll(keepingCapacity: true)
                }
            }
            group.append(edge)
        }
        finishGroup()
        return results
    }
}
