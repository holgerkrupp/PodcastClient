import Foundation
import CryptoKit
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

    private var cachedDocuments: [String: ShownoteDocument] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 64

    func parse(_ html: String) -> ShownoteDocument {
        let key = SHA256.hash(data: Data(html.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        if let cached = cachedDocuments[key] {
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            return cached
        }
        let signpostID = OSSignpostID(log: ShownotePerformance.log)
        os_signpost(.begin, log: ShownotePerformance.log, name: "Shownote parse", signpostID: signpostID)
        defer { os_signpost(.end, log: ShownotePerformance.log, name: "Shownote parse", signpostID: signpostID) }
        let document = ShownoteDocument(html: html)
        cachedDocuments[key] = document
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cachedDocuments.removeValue(forKey: evicted)
        }
        return document
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

        let inlineCandidates = candidates.filter { $0.presentation == .inline }
        let standaloneCandidates = candidates
            .filter { $0.presentation == .standalone }
            .sorted { $0.sourceRange.location < $1.sourceRange.location }

        guard standaloneCandidates.isEmpty == false else {
            let value = ShownoteHTMLLinkifier.linkify(html, candidates: inlineCandidates)
            return value.isEmpty ? [] : [.html(id: "html-0", value: value)]
        }

        var blocks: [ShownoteContentBlock] = []
        var cursor = 0

        for (index, candidate) in standaloneCandidates.enumerated() {
            let range = candidate.sourceRange
            guard range.location >= cursor, range.end <= html.utf16.count else { continue }
            let start = String.Index(utf16Offset: cursor, in: html)
            let candidateStart = String.Index(utf16Offset: range.location, in: html)

            let rawPrefix = String(html[start..<candidateStart])
            let prefix = HTMLFragmentBoundary.normalized(
                ShownoteHTMLLinkifier.linkifyFragment(
                    rawPrefix,
                    originalStart: cursor,
                    candidates: inlineCandidates
                ),
                isPrefix: true
            )
            if prefix.isEmpty == false {
                blocks.append(.html(id: "html-\(index)-\(cursor)", value: prefix))
            }
            blocks.append(.link(id: candidate.id, candidate: candidate))
            cursor = range.end
        }

        if cursor < html.utf16.count {
            let start = String.Index(utf16Offset: cursor, in: html)
            let rawSuffix = String(html[start...])
            let suffix = HTMLFragmentBoundary.normalized(
                ShownoteHTMLLinkifier.linkifyFragment(
                    rawSuffix,
                    originalStart: cursor,
                    candidates: inlineCandidates
                ),
                isPrefix: false
            )
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

        return candidates
            .map { candidate in
                var candidate = candidate
                candidate.presentation = presentation(for: candidate, in: html)
                return candidate
            }
            .sorted { $0.sourceRange.location < $1.sourceRange.location }
    }

    private struct BlockRange {
        let start: Int
        let contentStart: Int
        let contentEnd: Int
        let end: Int
    }

    /// Finds the nearest block element around an occurrence. This forgiving
    /// scanner is intentional: malformed feed HTML should still degrade to a
    /// normal link instead of breaking extraction or list structure.
    private static func presentation(
        for candidate: ShownoteLinkCandidate,
        in html: String
    ) -> ShownoteLinkPresentation {
        guard candidate.occurrenceKind != .email else { return .inline }

        let containingBlock = blockRanges(in: html)
            .filter {
                $0.start <= candidate.sourceRange.location
                    && candidate.sourceRange.end <= $0.end
            }
            .min { lhs, rhs in
                (lhs.end - lhs.start) < (rhs.end - rhs.start)
            }

        let contentStart = containingBlock?.contentStart ?? 0
        let contentEnd = containingBlock?.contentEnd ?? html.utf16.count
        guard contentStart <= contentEnd,
              candidate.sourceRange.location >= contentStart,
              candidate.sourceRange.end <= contentEnd
        else { return .inline }

        let start = String.Index(utf16Offset: contentStart, in: html)
        let end = String.Index(utf16Offset: contentEnd, in: html)
        var content = String(html[start..<end])
        let localStart = candidate.sourceRange.location - contentStart
        let localEnd = candidate.sourceRange.end - contentStart
        let candidateStart = String.Index(utf16Offset: localStart, in: content)
        let candidateEnd = String.Index(utf16Offset: localEnd, in: content)
        content.removeSubrange(candidateStart..<candidateEnd)

        return visibleText(from: content).isEmpty ? .standalone : .inline
    }

    private static func blockRanges(in html: String) -> [BlockRange] {
        let blockNames = Set([
            "address", "article", "aside", "blockquote", "dd", "div", "dl", "dt",
            "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6",
            "header", "li", "main", "nav", "ol", "p", "pre", "section", "table",
            "tbody", "td", "tfoot", "th", "thead", "tr", "ul"
        ])
        let voidNames = Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"])
        let tags = matches(of: #"(?is)<!--[\s\S]*?-->|</?[A-Za-z][^>]*>"#, in: html)
        var stack: [(name: String, start: Int, contentStart: Int)] = []
        var ranges: [BlockRange] = []

        for tag in tags {
            guard let parsed = tagName(in: tag.value), blockNames.contains(parsed.name) else { continue }
            if parsed.isClosing {
                guard let index = stack.lastIndex(where: { $0.name == parsed.name }) else { continue }
                let opening = stack[index]
                stack.removeSubrange(index...)
                ranges.append(
                    BlockRange(
                        start: opening.start,
                        contentStart: opening.contentStart,
                        contentEnd: tag.range.location,
                        end: tag.range.location + tag.range.length
                    )
                )
            } else if tag.value.hasSuffix("/>") == false, voidNames.contains(parsed.name) == false {
                stack.append((parsed.name, tag.range.location, tag.range.location + tag.range.length))
            }
        }

        for opening in stack {
            ranges.append(
                BlockRange(
                    start: opening.start,
                    contentStart: opening.contentStart,
                    contentEnd: html.utf16.count,
                    end: html.utf16.count
                )
            )
        }
        return ranges
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
        let withoutNonContent = html
            .replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>[\s\S]*?</\1\s*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        let withoutTags = withoutNonContent.replacingOccurrences(of: #"(?is)<[^>]*>"#, with: "", options: .regularExpression)
        return decodeHTMLEntities(withoutTags)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tagName(in tag: String) -> (name: String, isClosing: Bool)? {
        let pattern = try? NSRegularExpression(pattern: #"(?is)^<\s*(/?)\s*([A-Za-z][A-Za-z0-9]*)\b"#)
        let range = NSRange(location: 0, length: tag.utf16.count)
        guard let match = pattern?.firstMatch(in: tag, options: [], range: range),
              let nameRange = Range(match.range(at: 2), in: tag) else { return nil }
        return (
            String(tag[nameRange]).lowercased(),
            match.range(at: 1).length > 0
        )
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

    static func linkifyFragment(
        _ fragment: String,
        originalStart: Int,
        candidates: [ShownoteLinkCandidate]
    ) -> String {
        let fragmentLength = fragment.utf16.count
        let localCandidates = candidates.compactMap { candidate -> ShownoteLinkCandidate? in
            guard candidate.sourceRange.location >= originalStart,
                  candidate.sourceRange.end <= originalStart + fragmentLength else { return nil }
            return ShownoteLinkCandidate(
                id: candidate.id,
                originalURL: candidate.originalURL,
                normalizedURL: candidate.normalizedURL,
                sourceRange: ShownoteSourceRange(
                    NSRange(
                        location: candidate.sourceRange.location - originalStart,
                        length: candidate.sourceRange.length
                    )
                ),
                publisherAnchorText: candidate.publisherAnchorText,
                occurrenceKind: candidate.occurrenceKind,
                displayText: candidate.displayText,
                sourceMarkup: candidate.sourceMarkup,
                presentation: candidate.presentation,
                classification: candidate.classification
            )
        }
        return linkify(fragment, candidates: localCandidates)
    }
}
