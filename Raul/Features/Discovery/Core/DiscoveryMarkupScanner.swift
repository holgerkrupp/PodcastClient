//
//  DiscoveryMarkupScanner.swift
//  Raul
//
//  A small, deliberately narrow extraction layer for the providers that read
//  public directory pages. The app has no HTML parser dependency, and pulling
//  one in for a handful of attribute lookups would not pay for itself — so this
//  stays scoped to "find a tag / attribute / embedded JSON value" and every
//  provider parser is covered by fixture-based tests.
//
//  Nothing in here throws on malformed input: missing markup yields `nil` and
//  the provider degrades to "currently unavailable" rather than crashing.
//

import Foundation

enum DiscoveryMarkupScanner {

    // MARK: - Tags and attributes

    /// All occurrences of `<name …>` in document order.
    static func tags(named name: String, in markup: String) -> [String] {
        let pattern = "<\(NSRegularExpression.escapedPattern(for: name))\\b[^>]*>"
        return matches(of: pattern, in: markup).map { $0.0 }
    }

    /// The value of `attribute` inside a single start tag.
    static func attribute(_ attribute: String, in tag: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: attribute))\\s*=\\s*[\"']([^\"']*)[\"']"
        return matches(of: pattern, in: tag).first?.1.first.map(decodingHTMLEntities)
    }

    /// `<meta property="og:title" content="…">` and friends.
    static func metaContent(property: String, in markup: String) -> String? {
        for tag in tags(named: "meta", in: markup) {
            let identifier = attribute("property", in: tag) ?? attribute("name", in: tag)
            guard identifier?.caseInsensitiveCompare(property) == .orderedSame,
                  let content = attribute("content", in: tag),
                  content.isEmpty == false else {
                continue
            }
            return content
        }
        return nil
    }

    /// Absolute URLs in the document matching a pattern, de-duplicated, in order.
    /// Handles the escaped (`https:\/\/…`) form used inside embedded JSON.
    static func urls(matching pattern: String, in markup: String) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        for (match, _) in matches(of: pattern, in: markup) {
            let cleaned = match.replacingOccurrences(of: "\\/", with: "/")
            guard seen.insert(cleaned).inserted, let url = URL(string: cleaned) else { continue }
            result.append(url)
        }

        return result
    }

    /// The first capture group of `pattern`, if it matches.
    static func firstCapture(of pattern: String, in text: String) -> String? {
        matches(of: pattern, in: text).first?.1.first
    }

    /// Every match's capture groups, in document order.
    static func captures(of pattern: String, in text: String) -> [[String]] {
        matches(of: pattern, in: text).map { $0.1 }
    }

    // MARK: - Embedded JSON values

    /// Value of a `"key":"value"` pair in embedded (possibly escaped) JSON,
    /// searching backwards from `index` within a bounded window.
    ///
    /// Single-page-application payloads inline one large object per item; the
    /// nearest preceding key inside a small window belongs to the item being
    /// read. The window keeps a missing field from silently borrowing a value
    /// from the previous item.
    static func precedingJSONString(
        key: String,
        before index: String.Index,
        in text: String,
        window: Int = 8000
    ) -> String? {
        precedingValue(afterNeedle: "\"\(key)\":\"", before: index, in: text, window: window)
    }

    /// Value that follows the last occurrence of `needle` before `index`.
    /// Used for keys whose value is not a plain string, e.g. `"slug":{"current":"…"}`.
    static func precedingValue(
        afterNeedle needle: String,
        before index: String.Index,
        in text: String,
        window: Int = 8000
    ) -> String? {
        let lowerBound = text.index(index, offsetBy: -window, limitedBy: text.startIndex) ?? text.startIndex
        let haystack = text[lowerBound..<index]

        guard let needleRange = haystack.range(of: needle, options: .backwards) else { return nil }

        let valueStart = needleRange.upperBound
        guard let valueEnd = unescapedQuote(in: haystack, from: valueStart) else { return nil }

        return decodingJSONEscapes(String(haystack[valueStart..<valueEnd]))
    }

    /// Value of a `"key":"value"` pair that appears after `index`, within a
    /// bounded window. Needed where an item's fields straddle its anchor.
    static func followingJSONString(
        key: String,
        after index: String.Index,
        in text: String,
        window: Int = 8000
    ) -> String? {
        let upperBound = text.index(index, offsetBy: window, limitedBy: text.endIndex) ?? text.endIndex
        let haystack = text[index..<upperBound]

        guard let keyRange = haystack.range(of: "\"\(key)\":\"") else { return nil }

        let valueStart = keyRange.upperBound
        guard let valueEnd = unescapedQuote(in: haystack, from: valueStart) else { return nil }

        return decodingJSONEscapes(String(haystack[valueStart..<valueEnd]))
    }

    /// Finds the closing quote of a JSON string, skipping `\"`.
    private static func unescapedQuote(in text: Substring, from start: Substring.Index) -> Substring.Index? {
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                guard let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) else { return nil }
                index = next
                continue
            }
            if character == "\"" {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - Text handling

    /// Turns `self.__next_f.push([1,"…"])`-style escaped payloads back into text.
    static func decodingJSONEscapes(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)

        var iterator = value.startIndex
        while iterator < value.endIndex {
            let character = value[iterator]
            guard character == "\\" else {
                result.append(character)
                iterator = value.index(after: iterator)
                continue
            }

            let escapeIndex = value.index(after: iterator)
            guard escapeIndex < value.endIndex else { break }

            switch value[escapeIndex] {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case "/": result.append("/")
            case "x", "u":
                let digits = value[escapeIndex] == "x" ? 2 : 4
                let hexStart = value.index(after: escapeIndex)
                guard let hexEnd = value.index(hexStart, offsetBy: digits, limitedBy: value.endIndex),
                      let scalarValue = UInt32(value[hexStart..<hexEnd], radix: 16),
                      let scalar = UnicodeScalar(scalarValue) else {
                    iterator = value.index(after: escapeIndex)
                    continue
                }
                result.unicodeScalars.append(scalar)
                iterator = hexEnd
                continue
            default:
                result.append(value[escapeIndex])
            }

            iterator = value.index(after: escapeIndex)
        }

        return result
    }

    /// Strips tags and decodes entities — enough to turn a directory blurb into
    /// plain text for a row subtitle.
    static func plainText(from markup: String) -> String {
        let withoutTags = markup.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: [.regularExpression]
        )

        return decodingHTMLEntities(withoutTags)
            .replacingOccurrences(of: "\\s+", with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodingHTMLEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }

        var result = value
        let namedEntities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&#39;": "'", "&nbsp;": " ", "&hellip;": "…",
            "&ndash;": "–", "&mdash;": "—", "&laquo;": "«", "&raquo;": "»",
            "&oacute;": "ó", "&aacute;": "á", "&eacute;": "é", "&iacute;": "í",
            "&uacute;": "ú", "&ccedil;": "ç", "&atilde;": "ã", "&otilde;": "õ",
            "&auml;": "ä", "&ouml;": "ö", "&uuml;": "ü", "&szlig;": "ß"
        ]

        for (entity, replacement) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement, options: [.caseInsensitive])
        }

        // Numeric entities (&#233; / &#xE9;)
        for (pattern, radix) in [("&#([0-9]+);", 10), ("&#x([0-9A-Fa-f]+);", 16)] {
            for (match, groups) in matches(of: pattern, in: result).reversed() {
                guard let raw = groups.first,
                      let scalarValue = UInt32(raw, radix: radix),
                      let scalar = UnicodeScalar(scalarValue) else { continue }
                result = result.replacingOccurrences(of: match, with: String(Character(scalar)))
            }
        }

        return result
    }

    // MARK: - Regex plumbing

    private static func matches(of pattern: String, in text: String) -> [(String, [String])] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }

            var groups: [String] = []
            for index in 1..<match.numberOfRanges {
                guard let groupRange = Range(match.range(at: index), in: text) else { continue }
                groups.append(String(text[groupRange]))
            }

            return (String(text[matchRange]), groups)
        }
    }
}
