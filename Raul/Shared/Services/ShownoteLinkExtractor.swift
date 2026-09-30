import Foundation
import os

struct ShownoteDocument: Sendable {
    let sourceHTML: String
    let candidates: [ShownoteLinkCandidate]
    let linkifiedHTML: String
    let blocks: [ShownoteContentBlock]

    init(html: String) {
        sourceHTML = html
        candidates = ShownoteLinkExtractor.extract(from: html)
        linkifiedHTML = ShownoteHTMLLinkifier.linkify(html, candidates: candidates)
        blocks = ShownoteContentBlock.make(from: html, candidates: candidates)
    }
}

actor ShownoteParser {
    static let shared = ShownoteParser()

    func parse(_ html: String) -> ShownoteDocument {
        let signpostID = OSSignpostID(log: ShownotePerformance.log)
        os_signpost(.begin, log: ShownotePerformance.log, name: "Shownote parse", signpostID: signpostID)
        defer { os_signpost(.end, log: ShownotePerformance.log, name: "Shownote parse", signpostID: signpostID) }
        return ShownoteDocument(html: html)
    }
}

private enum ShownotePerformance {
    static let log = OSLog(subsystem: "de.holgerkrupp.PodcastClient", category: "Shownotes")
}

enum ShownoteContentBlock: Identifiable, Sendable {
    case html(id: String, value: String)
    case link(id: String, candidate: ShownoteLinkCandidate)

    var id: String {
        switch self {
        case .html(let id, _), .link(let id, _): return id
        }
    }

    static func make(from html: String, candidates: [ShownoteLinkCandidate]) -> [ShownoteContentBlock] {
        guard candidates.isEmpty == false else {
            return html.isEmpty ? [] : [.html(id: "html-0", value: html)]
        }

        let sorted = candidates.sorted { $0.sourceRange.location < $1.sourceRange.location }
        var blocks: [ShownoteContentBlock] = []
        var cursor = 0

        for (index, candidate) in sorted.enumerated() {
            let range = candidate.sourceRange
            guard range.location >= cursor, range.end <= html.utf16.count else { continue }
            let start = String.Index(utf16Offset: cursor, in: html)
            let candidateStart = String.Index(utf16Offset: range.location, in: html)

            let prefix = HTMLFragmentBoundary.normalized(String(html[start..<candidateStart]), isPrefix: true)
            if prefix.isEmpty == false {
                blocks.append(.html(id: "html-\(index)-\(cursor)", value: prefix))
            }
            blocks.append(.link(id: candidate.id, candidate: candidate))
            cursor = range.end
        }

        if cursor < html.utf16.count {
            let start = String.Index(utf16Offset: cursor, in: html)
            let suffix = HTMLFragmentBoundary.normalized(String(html[start...]), isPrefix: false)
            if suffix.isEmpty == false {
                blocks.append(.html(id: "html-tail-\(cursor)", value: suffix))
            }
        }
        return blocks
    }
}

/// Enriched cards are SwiftUI siblings of RichText fragments. Removing only
/// empty structural wrappers at a fragment boundary keeps the surrounding
/// HTML readable without producing an empty `<li>`/`<p>` for the card.
private enum HTMLFragmentBoundary {
    private static let blockNames = "address|article|aside|blockquote|dd|div|dl|dt|figcaption|figure|footer|h[1-6]|header|li|main|nav|ol|p|pre|section|table|tbody|td|tfoot|th|thead|tr|ul"

    static func normalized(_ fragment: String, isPrefix: Bool) -> String {
        var value = fragment
        value = isPrefix ? removeTrailingOpeningBlocks(from: value) : removeLeadingClosingBlocks(from: value)

        let visible = value
            .replacingOccurrences(of: #"(?is)<[^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"&(?:nbsp|#160);"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return visible.isEmpty ? "" : value
    }

    private static func removeTrailingOpeningBlocks(from value: String) -> String {
        let pattern = "(?is)(?:\\s*<(?!(?:/|!))(?:\(blockNames))\\b[^>]*>)+\\s*$"
        return value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    private static func removeLeadingClosingBlocks(from value: String) -> String {
        let pattern = "(?is)^\\s*(?:</(?:\(blockNames))\\s*>\\s*)+"
        return value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
}

enum ShownoteLinkExtractor {
    private static let maximumParsingCharacters = 500_000

    static func extract(from html: String) -> [ShownoteLinkCandidate] {
        guard html.isEmpty == false else { return [] }
        let html = html.count > maximumParsingCharacters
            ? String(html.prefix(maximumParsingCharacters))
            : html

        let tagRanges = matches(of: #"(?is)<!--.*?-->|<[^>]*>"#, in: html)
        let anchorMatches = matches(of: #"(?is)<a\b[^>]*>.*?</a\s*>"#, in: html)
        var candidates: [ShownoteLinkCandidate] = []
        var occupied = Set<ShownoteSourceRange>()

        for match in anchorMatches {
            guard let href = attribute(named: "href", in: match.value),
                  let url = URL(string: decodeHTMLEntities(href)),
                  let normalized = ShownoteURLNormalization.normalized(url),
                  url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"
            else { continue }

            let range = ShownoteSourceRange(match.range)
            occupied.insert(range)
            let displayText = visibleText(from: match.value)
            candidates.append(
                ShownoteLinkCandidate(
                    id: occurrenceID(normalized: normalized, range: range),
                    originalURL: url,
                    normalizedURL: normalized,
                    sourceRange: range,
                    publisherAnchorText: displayText.isEmpty ? nil : displayText,
                    occurrenceKind: .publisherAnchor,
                    displayText: displayText.isEmpty ? url.absoluteString : displayText,
                    sourceMarkup: match.value
                )
            )
        }

        let excludedRanges = (tagRanges.map { ShownoteSourceRange($0.range) } + Array(occupied))
            .sorted { $0.location < $1.location }
        var textRanges: [ShownoteSourceRange] = []
        var cursor = 0
        for range in excludedRanges {
            if range.location > cursor {
                textRanges.append(ShownoteSourceRange(NSRange(location: cursor, length: range.location - cursor)))
            }
            cursor = max(cursor, range.end)
        }
        if cursor < html.utf16.count {
            textRanges.append(ShownoteSourceRange(NSRange(location: cursor, length: html.utf16.count - cursor)))
        }

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let emailRegex = try? NSRegularExpression(
            pattern: #"(?i)(?<![A-Z0-9._%+\-])[A-Z0-9._%+\-]+@[A-Z0-9\-]+(?:\.[A-Z0-9\-]+)+"#,
            options: []
        )

        for textRange in textRanges {
            let start = String.Index(utf16Offset: textRange.location, in: html)
            let end = String.Index(utf16Offset: textRange.end, in: html)
            let text = String(html[start..<end])
            let localRange = NSRange(location: 0, length: text.utf16.count)
            for match in detector?.matches(in: text, options: [], range: localRange) ?? [] {
                guard match.resultType == .link, let detectedURL = match.url,
                      let rawRange = Range(match.range, in: text) else { continue }
                let scheme = detectedURL.scheme?.lowercased()
                guard scheme == "http" || scheme == "https" || scheme == "mailto" else { continue }

                let raw = String(text[rawRange])
                let trimmed = trimSentencePunctuation(raw)
                guard trimmed.isEmpty == false,
                      let url = URL(string: decodeHTMLEntities(trimmed)),
                      let normalized = ShownoteURLNormalization.normalized(url) else { continue }
                let localOffset = match.range.location
                let globalLocation = textRange.location + localOffset
                let range = ShownoteSourceRange(NSRange(location: globalLocation, length: trimmed.utf16.count))
                guard candidates.contains(where: { rangesOverlap($0.sourceRange, range) }) == false else { continue }

                candidates.append(
                    ShownoteLinkCandidate(
                        id: occurrenceID(normalized: normalized, range: range),
                        originalURL: url,
                        normalizedURL: normalized,
                        sourceRange: range,
                        publisherAnchorText: nil,
                        occurrenceKind: scheme == "mailto" ? .email : .plainText,
                        displayText: trimmed,
                        sourceMarkup: trimmed
                    )
                )
            }

            for match in emailRegex?.matches(in: text, options: [], range: localRange) ?? [] {
                guard let rawRange = Range(match.range, in: text) else { continue }
                let raw = String(text[rawRange])
                let trimmed = trimSentencePunctuation(raw)
                guard trimmed.isEmpty == false,
                      let url = URL(string: "mailto:\(decodeHTMLEntities(trimmed))"),
                      let normalized = ShownoteURLNormalization.normalized(url) else { continue }
                let range = ShownoteSourceRange(
                    NSRange(location: textRange.location + match.range.location, length: trimmed.utf16.count)
                )
                guard candidates.contains(where: { rangesOverlap($0.sourceRange, range) }) == false else { continue }

                candidates.append(
                    ShownoteLinkCandidate(
                        id: occurrenceID(normalized: normalized, range: range),
                        originalURL: url,
                        normalizedURL: normalized,
                        sourceRange: range,
                        publisherAnchorText: nil,
                        occurrenceKind: .email,
                        displayText: trimmed,
                        sourceMarkup: trimmed
                    )
                )
            }
        }

        return candidates.sorted { $0.sourceRange.location < $1.sourceRange.location }
    }

    private struct Match {
        let range: NSRange
        let value: String
    }

    private static func matches(of pattern: String, in string: String) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(location: 0, length: string.utf16.count)
        return regex.matches(in: string, options: [], range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: string) else { return nil }
            return Match(range: match.range, value: String(string[swiftRange]))
        }
    }

    private static func attribute(named name: String, in tag: String) -> String? {
        let patterns = [
            "(?i)\\b" + name + "\\s*=\\s*\"([^\"]*)\"",
            "(?i)\\b" + name + "\\s*=\\s*'([^']*)'"
        ]
        let searchRange = NSRange(location: 0, length: tag.utf16.count)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
                  let match = regex.firstMatch(in: tag, options: [], range: searchRange),
                  let valueRange = Range(match.range(at: 1), in: tag) else { continue }
            return String(tag[valueRange])
        }
        return nil
    }

    private static func visibleText(from html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: #"(?is)<[^>]*>"#, with: "", options: .regularExpression)
        return decodeHTMLEntities(withoutTags).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        var result = value
        ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">"].forEach {
            result = result.replacingOccurrences(of: $0.key, with: $0.value)
        }
        return result
    }

    private static func trimSentencePunctuation(_ value: String) -> String {
        var result = value
        let trailing = CharacterSet(charactersIn: ".,!?;:\"'»、。！？")
        while let last = result.unicodeScalars.last, trailing.contains(last) {
            result.removeLast()
        }
        if result.last == ")" && result.filter({ $0 == "(" }).count < result.filter({ $0 == ")" }).count {
            result.removeLast()
        }
        if result.last == "]" && result.filter({ $0 == "[" }).count < result.filter({ $0 == "]" }).count {
            result.removeLast()
        }
        return result
    }

    private static func occurrenceID(normalized: URL, range: ShownoteSourceRange) -> String {
        "\(normalized.absoluteString)#\(range.location)-\(range.length)"
    }

    private static func rangesOverlap(_ lhs: ShownoteSourceRange, _ rhs: ShownoteSourceRange) -> Bool {
        lhs.location < rhs.end && rhs.location < lhs.end
    }
}

enum ShownoteURLNormalization {
    static func normalized(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "mailto" {
            return url
        }
        guard ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), host.isEmpty == false else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = scheme
        components.host = host
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        components.fragment = nil
        return components.url
    }
}

enum ShownoteHTMLLinkifier {
    static func linkify(_ html: String, candidates: [ShownoteLinkCandidate]) -> String {
        let plainCandidates = candidates.filter {
            $0.occurrenceKind == .plainText || $0.occurrenceKind == .email
        }
        guard plainCandidates.isEmpty == false else { return html }
        var result = html
        for candidate in plainCandidates.sorted(by: { $0.sourceRange.location > $1.sourceRange.location }) {
            let start = String.Index(utf16Offset: candidate.sourceRange.location, in: result)
            let end = String.Index(utf16Offset: candidate.sourceRange.end, in: result)
            let text = String(result[start..<end])
            let escapedURL = candidate.originalURL.absoluteString
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            let replacement = "<a href=\"\(escapedURL)\">\(text)</a>"
            result.replaceSubrange(start..<end, with: replacement)
        }
        return result
    }
}
