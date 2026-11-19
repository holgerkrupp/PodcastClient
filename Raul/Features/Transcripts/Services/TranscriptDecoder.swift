//
//  TranscriptDecoder.swift
//  Raul
//
//  Created by Holger Krupp on 27.05.25.
//

import Foundation

@Observable
class TranscriptDecoder{
    
    var transcriptContent: String = ""
    var transcriptLines: [TranscriptLineWithTime] = []
    
    
    struct TranscriptLineWithTime: Identifiable, Sendable, Equatable {
        let id: UUID
        let speaker: String?
        var text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        var timedSpans: [TranscriptTimedSpan] = []
    }
    
    private enum TranscriptFormat {
        case webVTT
        case inline
        case srt
        case json // MARK: - JSON Transcript Support
        case unknown
    }

    
    init (_ string: String) {
        self.transcriptContent = string
        transcriptLines  = parseAllLines()
    }
    
    func reload(with content: String) {
        self.transcriptContent = content
        self.transcriptLines = parseAllLines()
    }
    
    
    private func detectFormat() -> TranscriptFormat {
        let trimmed = transcriptContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if transcriptContent.contains("WEBVTT") {
            return .webVTT
        } else if transcriptContent.range(of: #"\(\d{1,2}:\d{2}\)"#, options: .regularExpression) != nil {
            return .inline
        } else if transcriptContent.range(of: #"^\d+\r?\n\d{2}:\d{2}:\d{2},"#, options: .regularExpression, range: nil, locale: nil) != nil {
            return .srt
        } else if transcriptContent.contains("{\"version\":") && transcriptContent.contains("\"segments\":") {
            return .json
        } else if transcriptContent.contains("{\"version\":") && transcriptContent.contains("\"chapters\":") {
            return .json
        } else if trimmed.hasPrefix("[") {
            // Heuristic for plain JSON array of segments/chapters without version
            // Look for common keys used in our models
            let hasStart = transcriptContent.contains("\"start\":") || transcriptContent.contains("\"startTime\":")
            let hasEnd = transcriptContent.contains("\"end\":") || transcriptContent.contains("\"endTime\":")
            let hasTextLike = transcriptContent.contains("\"text\":") || transcriptContent.contains("\"body\":") || transcriptContent.contains("\"title\":")
            if hasTextLike && (hasStart || hasEnd) {
                return .json
            }
        }
        return .unknown
    }
    
    private func parseAllLines() -> [TranscriptLineWithTime] {
        let format = detectFormat()
        print(format)
        switch format {
        case .webVTT:
            return parseWebVTT()
        case .inline:
            return parseInlineTranscript()
        case .srt:
            return parseSRT()
        case .json: // MARK: - JSON Transcript Support
            return parseJSONTranscript()
        case .unknown:
            return parseJSONTranscript() // Fall back to at least try JSON decoding
        
        }
    }
    //MARK: WebVTT
    private func parseWebVTT() -> [TranscriptLineWithTime] {
        let linesArray = transcriptContent.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var transcriptLines: [TranscriptLineWithTime] = []
        var currentIndex = 0

        while currentIndex < linesArray.count {
            let timestampLine = linesArray[currentIndex]
            let parts = timestampLine.components(separatedBy: " --> ")
            guard parts.count == 2,
                  let startTime = webVTTTime(parts[0].trimmingCharacters(in: .whitespaces)),
                  let endToken = parts[1].split(whereSeparator: \.isWhitespace).first,
                  let endTime = webVTTTime(String(endToken)), endTime > startTime else {
                currentIndex += 1
                continue
            }
            currentIndex += 1
            var textLines: [String] = []
            while currentIndex < linesArray.count && !linesArray[currentIndex].isEmpty {
                textLines.append(linesArray[currentIndex])
                currentIndex += 1
            }
            var rawText = textLines.joined(separator: "\n")
            var speaker: String?
            if rawText.hasPrefix("<v "), let end = rawText.firstIndex(of: ">") {
                speaker = String(rawText[rawText.index(rawText.startIndex, offsetBy: 3)..<end])
                rawText.removeSubrange(rawText.startIndex...end)
                if rawText.hasSuffix("</v>") { rawText.removeLast(4) }
            }
            let parsed = webVTTText(rawText, start: startTime, end: endTime)
            transcriptLines.append(TranscriptLineWithTime(
                id: UUID(), speaker: speaker, text: parsed.text,
                startTime: startTime, endTime: endTime, timedSpans: parsed.spans
            ))
        }
        return sortedTranscriptLines(transcriptLines)
    }

    private func webVTTTime(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty }),
              let seconds = Double(parts.last!), seconds >= 0, seconds < 60,
              let minutes = Double(parts[parts.count - 2]), minutes >= 0, minutes < 60 else { return nil }
        let hours: Double
        if parts.count == 3 {
            guard let parsed = Double(parts[0]), parsed >= 0 else { return nil }
            hours = parsed
        } else {
            hours = 0
        }
        let time = hours * 3600 + minutes * 60 + seconds
        return time.isFinite ? time : nil
    }

    private func webVTTText(_ raw: String, start: TimeInterval, end: TimeInterval) -> (text: String, spans: [TranscriptTimedSpan]) {
        let pattern = #"<(?:\d{2,}:)?\d{2}:\d{2}\.\d{3}>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (raw, []) }
        let nsRaw = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: nsRaw.length))
        guard !matches.isEmpty else { return (raw, []) }
        var text = ""
        var spans: [TranscriptTimedSpan] = []
        var sourceOffset = 0
        var spanStart = start
        var valid = true
        for match in matches {
            let chunk = nsRaw.substring(with: NSRange(location: sourceOffset, length: match.range.location - sourceOffset))
            let location = text.utf16.count
            text += chunk
            let tag = nsRaw.substring(with: match.range)
            guard let time = webVTTTime(String(tag.dropFirst().dropLast())) else { return (raw, []) }
            if time <= spanStart || time >= end { valid = false }
            if !chunk.isEmpty {
                spans.append(TranscriptTimedSpan(location: location, length: chunk.utf16.count, startTime: spanStart, endTime: time))
            }
            spanStart = time
            sourceOffset = NSMaxRange(match.range)
        }
        let tail = nsRaw.substring(from: sourceOffset)
        let location = text.utf16.count
        text += tail
        if !tail.isEmpty {
            spans.append(TranscriptTimedSpan(location: location, length: tail.utf16.count, startTime: spanStart, endTime: end))
        }
        return (text, valid ? spans : [])
    }
    
    private func separateSpeakerAndText(from line: String) -> (speaker: String?, text: String) {
        let components = line.components(separatedBy: ">")
        
        if components.count > 1 {
            var speaker = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if speaker.hasPrefix("<v ") {
                speaker.removeFirst(3)
            }
            let text = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return (speaker, text)
        } else {
            return (nil, line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    
    private func formatTime(_ timeInterval: TimeInterval) -> String {
        let minutes = Int(timeInterval) / 60
        let seconds = Int(timeInterval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    //MARK: Inline
    private func parseInlineTranscript() -> [TranscriptLineWithTime] {
        let lines = transcriptContent.components(separatedBy: .newlines)
        var results: [TranscriptLineWithTime] = []

        var currentSpeaker: String?
        var currentText: String = ""
        var previousEndTime: TimeInterval = 0

        let timePattern = #"\((\d{1,2}):(\d{2})\)"#
        let timeRegex = try? NSRegularExpression(pattern: timePattern)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if let match = timeRegex?.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)),
               let range = Range(match.range, in: trimmed) {

                // Extract time from current line (this is the END time)
                let minute = Int(trimmed[Range(match.range(at: 1), in: trimmed)!]) ?? 0
                let second = Int(trimmed[Range(match.range(at: 2), in: trimmed)!]) ?? 0
                let currentEndTime = TimeInterval(minute * 60 + second)

                // Save previous block
                if let speaker = currentSpeaker, !currentText.isEmpty {
                    results.append(
                        TranscriptLineWithTime(
                            id: UUID(),
                            speaker: speaker,
                            text: currentText.trimmingCharacters(in: .whitespaces),
                            startTime: previousEndTime,
                            endTime: currentEndTime
                        )
                    )
                }

                // Prepare next block
                let speakerName = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                currentSpeaker = speakerName
                previousEndTime = currentEndTime
                currentText = ""

            } else {
                currentText += trimmed + " "
            }
        }

        // Final block if any
        if let speaker = currentSpeaker, !currentText.isEmpty {
            results.append(
                TranscriptLineWithTime(
                    id: UUID(),
                    speaker: speaker,
                    text: currentText.trimmingCharacters(in: .whitespaces),
                    startTime: previousEndTime,
                    endTime: previousEndTime + 5 // fallback estimate
                )
            )
        }
        
        results.sort { $0.startTime < $1.startTime }

        return sortedTranscriptLines(results)
    }

    //MARK: SRT
    private func parseSRT() -> [TranscriptLineWithTime] {
        let blocks = transcriptContent.components(separatedBy: "\n\n")
        var results: [TranscriptLineWithTime] = []

        for block in blocks {
            let lines = block.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard lines.count >= 3 else { continue }

            // Format:
            // Line 0: numeric index
            // Line 1: "00:00:01,000 --> 00:00:04,000"
            // Line 2...: text (possibly multiple lines)

            let timestampLine = lines[1]
            let timestampParts = timestampLine.components(separatedBy: " --> ")
            guard timestampParts.count == 2,
                  let startTime = timestampParts[0].srtDurationAsSeconds,
                  let endTime = timestampParts[1].srtDurationAsSeconds
            else { continue }

            let textLines = lines[2...].joined(separator: " ")
            let (speaker, text) = separateSpeakerAndText(from: textLines)

            results.append(
                TranscriptLineWithTime(
                    id: UUID(),
                    speaker: speaker,
                    text: text,
                    startTime: startTime,
                    endTime: endTime
                )
            )
        }

        return sortedTranscriptLines(results)
    }

    // MARK: - JSON Transcript Support
    private struct JSONTranscript: Decodable {
        let version: String
        let segments: [Segment]?
        let chapters: [Chapter]?
        
        struct Segment: Decodable {
            let speaker: String
            let startTime: Double
            let endTime: Double
            let body: String

            private enum CodingKeys: String, CodingKey {
                case speaker
                case body
                case startTime
                case endTime
                case start
                case end
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.speaker = try container.decode(String.self, forKey: .speaker)
                self.body = try container.decode(String.self, forKey: .body)

                // Prefer startTime/endTime if present, otherwise fall back to start/end
                if let st = try container.decodeIfPresent(Double.self, forKey: .startTime) {
                    self.startTime = st
                } else if let st = try container.decodeIfPresent(Double.self, forKey: .start) {
                    self.startTime = st
                } else {
                    throw DecodingError.keyNotFound(CodingKeys.startTime, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing startTime/start"))
                }

                if let et = try container.decodeIfPresent(Double.self, forKey: .endTime) {
                    self.endTime = et
                } else if let et = try container.decodeIfPresent(Double.self, forKey: .end) {
                    self.endTime = et
                } else {
                    throw DecodingError.keyNotFound(CodingKeys.endTime, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing endTime/end"))
                }
            }
        }

        struct Chapter: Decodable {
            let startTime: Double
            let title: String
            let endTime: Double?

            private enum CodingKeys: String, CodingKey {
                case title
                case startTime
                case endTime
                case start
                case end
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.title = try container.decode(String.self, forKey: .title)

                if let st = try container.decodeIfPresent(Double.self, forKey: .startTime) {
                    self.startTime = st
                } else if let st = try container.decodeIfPresent(Double.self, forKey: .start) {
                    self.startTime = st
                } else {
                    throw DecodingError.keyNotFound(CodingKeys.startTime, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing startTime/start"))
                }

                if let et = try container.decodeIfPresent(Double.self, forKey: .endTime) {
                    self.endTime = et
                } else if let et = try container.decodeIfPresent(Double.self, forKey: .end) {
                    self.endTime = et
                } else {
                    self.endTime = nil
                }
            }
        }
    }
    
    // Fallback plain array support for JSON transcripts without a wrapper
    private struct PlainSegment: Decodable {
        let speaker: String?
        let text: String
        let startTime: Double
        let endTime: Double

        private enum CodingKeys: String, CodingKey {
            case speaker
            case text
            case body
            case startTime
            case endTime
            case start
            case end
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.speaker = try container.decodeIfPresent(String.self, forKey: .speaker)

            if let body = try container.decodeIfPresent(String.self, forKey: .body) {
                self.text = body
            } else if let text = try container.decodeIfPresent(String.self, forKey: .text) {
                self.text = text
            } else {
                throw DecodingError.keyNotFound(CodingKeys.body, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing text/body"))
            }

            if let st = try container.decodeIfPresent(Double.self, forKey: .startTime) {
                self.startTime = st
            } else if let st = try container.decodeIfPresent(Double.self, forKey: .start) {
                self.startTime = st
            } else {
                throw DecodingError.keyNotFound(CodingKeys.startTime, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing startTime/start"))
            }

            if let et = try container.decodeIfPresent(Double.self, forKey: .endTime) {
                self.endTime = et
            } else if let et = try container.decodeIfPresent(Double.self, forKey: .end) {
                self.endTime = et
            } else {
                throw DecodingError.keyNotFound(CodingKeys.endTime, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing endTime/end"))
            }
        }
    }

    private func parseJSONTranscript() -> [TranscriptLineWithTime] {
        print("parseJSONTranscript")
        guard let data = transcriptContent.data(using: .utf8) else {
            print("no utf8")
            return []
        }
        let decoder = JSONDecoder()
        // First try the wrapped format { version, segments/chapters }
        if let decoded = try? decoder.decode(JSONTranscript.self, from: data) {
            print("decoded wrapped JSONTranscript: segments=\(decoded.segments?.count ?? 0), chapters=\(decoded.chapters?.count ?? 0)")
            if let segments = decoded.segments {
                let results = segments.map { segment in
                    TranscriptLineWithTime(
                        id: UUID(),
                        speaker: segment.speaker,
                        text: segment.body,
                        startTime: segment.startTime,
                        endTime: segment.endTime
                    )
                }
                return sortedTranscriptLines(results)
            } else if let chapters = decoded.chapters {
                var results: [TranscriptLineWithTime] = []
                for (index, chapter) in chapters.enumerated() {
                    let startTime = chapter.startTime
                    let endTime: TimeInterval
                    if let chapterEnd = chapter.endTime {
                        endTime = chapterEnd
                    } else if index + 1 < chapters.count {
                        endTime = chapters[index + 1].startTime
                    } else {
                        endTime = startTime + 5
                    }
                    results.append(
                        TranscriptLineWithTime(
                            id: UUID(),
                            speaker: nil,
                            text: chapter.title,
                            startTime: startTime,
                            endTime: endTime
                        )
                    )
                }
                return sortedTranscriptLines(results)
            } else {
                return []
            }
        }

        // Fallback: try a plain array of segments
        if let array = try? decoder.decode([PlainSegment].self, from: data) {
            print("decoded plain array: \(array.count) segments")
            let results = array.map { seg in
                TranscriptLineWithTime(
                    id: UUID(),
                    speaker: seg.speaker,
                    text: seg.text,
                    startTime: seg.startTime,
                    endTime: seg.endTime
                )
            }
            return sortedTranscriptLines(results)
        }

        print("decode failed for both wrapped and plain formats")
        return []
    }

    private func sortedTranscriptLines(_ lines: [TranscriptLineWithTime]) -> [TranscriptLineWithTime] {
        lines.enumerated().sorted { left, right in
            if left.element.startTime != right.element.startTime {
                return left.element.startTime < right.element.startTime
            }
            return left.offset < right.offset
        }.map(\.element)
    }
    
}
private extension String {
    var srtDurationAsSeconds: TimeInterval? {
        let components = self.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard components.count == 3,
              let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]) else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }
}
