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

        // Order matters: preserve explicit line and block boundaries before
        // removing the remaining markup. NSAttributedString's HTML importer is
        // intentionally avoided here because it can collapse these boundaries
        // and is not safe to use from EpisodeActor on every supported platform.
        let newlineReplacements: [(needle: String, replacement: String)] = [
            ("\r\n", "\n"),
            ("\r", "\n"),
            ("\u{2028}", "\n"),
            ("\u{2029}", "\n"),
            ("\u{0085}", "\n")
        ]
        for (needle, replacement) in newlineReplacements {
            text = text.replacingOccurrences(of: needle, with: replacement)
        }

        text = text.replacingOccurrences(of: "<![CDATA[", with: "")
        text = text.replacingOccurrences(of: "]]>", with: "")
        text = text.replacingOccurrences(
            of: #"(?is)<!--.*?-->"#,
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#,
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"<\s*/?\s*(?:br|p|div|li|ul|ol|dl|dt|dd|tr|td|th|table|section|article|header|footer|blockquote|pre|hr|h[1-6])(?:\s[^>]*)?/?\s*>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)

        // Decode entities only after markup removal so an encoded angle bracket
        // cannot accidentally be interpreted as an HTML tag.
        text = decodingHTMLEntities(in: text)
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")

        text = text.replacingOccurrences(
            of: #"(?<=[^\s\d:])(?=\s*(?:(?:\d{1,2}:[0-5]\d:[0-5]\d)|(?:[0-5]?\d:[0-5]\d))\s*(?:[-–—:|•·]|\s+[^\d\s]))"#,
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedHTMLEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "ndash": "–", "mdash": "—", "hellip": "…",
        "bull": "•", "middot": "·", "laquo": "«", "raquo": "»",
        "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’",
        "sbquo": "‚", "bdquo": "„", "minus": "−", "times": "×",
        "deg": "°", "euro": "€", "pound": "£", "copy": "©",
        "reg": "®", "trade": "™", "auml": "ä", "ouml": "ö",
        "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü",
        "szlig": "ß", "agrave": "à", "eacute": "é", "egrave": "è",
        "ccedil": "ç"
    ]

    private static func decodingHTMLEntities(in text: String) -> String {
        guard text.contains("&"),
              let entityRegex = try? NSRegularExpression(
                pattern: #"&(#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});"#
              ) else { return text }

        let nsText = text as NSString
        let matches = entityRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard matches.isEmpty == false else { return text }

        var decoded = ""
        var copiedUpTo = 0
        for match in matches {
            decoded += nsText.substring(
                with: NSRange(location: copiedUpTo, length: match.range.location - copiedUpTo)
            )
            let entityBody = nsText.substring(with: match.range(at: 1))
            decoded += replacement(forEntityBody: entityBody) ?? nsText.substring(with: match.range)
            copiedUpTo = match.range.upperBound
        }
        decoded += nsText.substring(from: copiedUpTo)
        return decoded
    }

    private static func replacement(forEntityBody entityBody: String) -> String? {
        guard entityBody.hasPrefix("#") else { return namedHTMLEntities[entityBody] }

        let digits = entityBody.dropFirst()
        let scalarValue: UInt32?
        if digits.first == "x" || digits.first == "X" {
            scalarValue = UInt32(digits.dropFirst(), radix: 16)
        } else {
            scalarValue = UInt32(digits, radix: 10)
        }

        guard let scalarValue, let scalar = Unicode.Scalar(scalarValue) else { return nil }
        return String(Character(scalar))
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
