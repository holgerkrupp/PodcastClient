//
//  ShownotesChapterExtractor.swift
//  Raul
//
//  Created by Codex on 13.05.26.
//

import Foundation

struct ShownotesChapterExtractor {
    static func extractTimeCodesAndTitles(fromShownotesCandidates candidates: [String?]) -> [String: String]? {
        for candidate in candidates {
            guard let candidate, candidate.isEmpty == false else { continue }
            if let chapters = extractTimeCodesAndTitles(from: candidate) {
                return chapters
            }
        }
        return nil
    }

    static func extractTimeCodesAndTitles(from htmlEncodedText: String) -> [String: String]? {
        let normalizedText = normalizedShownotesTextForChapterParsing(from: htmlEncodedText)
        let nsText = normalizedText as NSString

        guard let timeRegex = try? NSRegularExpression(
            pattern: #"(?<![\d:])((?:\d{1,2}:[0-5]\d:[0-5]\d)|(?:[0-5]?\d:[0-5]\d))(?![\d:])"#
        ) else { return nil }

        let matches = timeRegex.matches(in: normalizedText, range: NSRange(location: 0, length: nsText.length))
        guard matches.isEmpty == false else { return nil }

        var parsedEntries: [(time: String, title: String)] = []

        for (index, match) in matches.enumerated() {
            guard match.numberOfRanges >= 2 else { continue }
            let rawTimeCode = nsText.substring(with: match.range(at: 1))
            guard let canonicalTimeCode = canonicalChapterTimeCode(from: rawTimeCode) else { continue }

            let titleStart = match.range.upperBound
            let titleEnd = index + 1 < matches.count ? matches[index + 1].range.lowerBound : nsText.length
            guard titleStart <= titleEnd else { continue }

            let rawTitleSegment = nsText.substring(with: NSRange(location: titleStart, length: titleEnd - titleStart))
            guard let title = extractChapterTitle(from: rawTitleSegment) else { continue }
            parsedEntries.append((canonicalTimeCode, title))
        }

        guard parsedEntries.count >= 2 else { return nil }

        var result: [String: String] = [:]
        for entry in parsedEntries {
            result[entry.time] = entry.title
        }
        return result.isEmpty ? nil : result
    }

    private static func normalizedShownotesTextForChapterParsing(from htmlEncodedText: String) -> String {
        var text = htmlEncodedText

        text = text.replacingOccurrences(
            of: #"<!\[CDATA\[(.*?)\]\]>"#,
            with: "$1",
            options: [.regularExpression, .caseInsensitive]
        )

        text = text.replacingOccurrences(
            of: #"<!--.*?-->"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )

        text = text.replacingOccurrences(
            of: #"<\s*br\s*/?\s*>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )

        text = text.replacingOccurrences(
            of: #"</?(?:p|li|div|ul|ol|h[1-6])\b[^>]*>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )

        text = text.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )

        text = text.decodeHTML() ?? text

        let replacements: [String: String] = [
            "\r\n": "\n",
            "\r": "\n",
            "\u{2028}": "\n",
            "\u{2029}": "\n",
            "\u{0085}": "\n",
            "\u{00A0}": " "
        ]
        for (needle, replacement) in replacements {
            text = text.replacingOccurrences(of: needle, with: replacement)
        }

        text = text.replacingOccurrences(
            of: #"(?<=[^\s\d:])(?=\s*(?:(?:\d{1,2}:[0-5]\d:[0-5]\d)|(?:[0-5]?\d:[0-5]\d))\s*(?:[-–—:|•·]|\s+[^\d\s]))"#,
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalChapterTimeCode(from rawValue: String) -> String? {
        let parts = rawValue.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }

        let hours: Int
        let minutes: Int
        let seconds: Int

        if parts.count == 2 {
            hours = 0
            minutes = parts[0]
            seconds = parts[1]
        } else {
            hours = parts[0]
            minutes = parts[1]
            seconds = parts[2]
        }

        guard (0..<60).contains(minutes), (0..<60).contains(seconds) else { return nil }
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private static func extractChapterTitle(from rawSegment: String) -> String? {
        let lines = rawSegment
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        for line in lines {
            var candidate = line
            candidate = candidate.replacingOccurrences(
                of: #"^[\-\–\—:\|•·*>\)\]\.]+\s*"#,
                with: "",
                options: .regularExpression
            )
            candidate = candidate.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

            if candidate.isEmpty == false {
                return candidate
            }
        }

        return nil
    }
}
